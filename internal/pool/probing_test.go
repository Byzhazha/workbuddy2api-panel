package pool

import (
	"testing"
	"time"

	"github.com/linguo2625469/workbuddy2api-panel/internal/auth"
)

// ---------------------------------------------------------------------------
// 「网关已放行、上游仍未恢复」（Probing）的台账/锁池口径。
//
// 背景：6004 带「将在 … 重置」时路由冷却 Until = min(resetAt, now+reset_honor_max)，
// 正常情况下 Until 就等于上游墙钟（429 后锁到恢复为止）。只有上游给的墙钟超出
// reset_honor_max（默认 24h，防年份写错）才会出现 Until < ResetAt：网关先放行、
// 但请求照样 429。旧实现按 Until 判「过期即从台账消失」，于是面板上什么都看不到
// ——「日志一直 429、面板却说可用」。下面三个用例把这个口径钉住：
//   1. 台账要出 Probing 行（含上游重置墙钟与封顶秒数）；
//   2. 惰性清理/落盘不得在 Until 到期时就把条目删掉（否则台账无从展示）；
//   3. 锁池把这类号算「不能用」（Servable 不数它），但状态标 probing。
// ---------------------------------------------------------------------------

// TestPinnedResetNotCalledByFallback 上游给了恢复时刻（「429 就别再调用它」）：
// 即便全池只剩这类冷却号，全冷却兜底也不得再调（调了必 429）。
// 对照：本地退避估算的软冷却仍允许半开探测（既有语义，见 TestFallbackSoftAndBreakerParticipate）。
func TestPinnedResetNotCalledByFallback(t *testing.T) {
	p := New("")
	p.Add(&auth.Auth{UID: "u1"})
	reset := time.Now().Add(time.Hour)
	p.CooldownSoftRate("u1", time.Minute, reset, "429 rate limit · glm-5.3")
	if got := p.Pick(); got != nil {
		t.Fatalf("上游明说到点才恢复的号不得被兜底调用，got %+v", got)
	}
	// 到点后正常回池（不是永久拉黑）。
	p.mu.Lock()
	e := p.byUID["u1"]
	e.until = time.Now().Add(-time.Second)
	p.mu.Unlock()
	if got := p.Pick(); got == nil || got.UID != "u1" {
		t.Fatalf("恢复时刻过后应重新可选，got %+v", got)
	}
}

// TestModelCooledNotCalledByFallback 模型级 6004 冷却中的号，兜底也不得再调该模型；
// 但换模型仍可用（6004 只锁模型，不锁账号）。
func TestModelCooledNotCalledByFallback(t *testing.T) {
	p := New("")
	p.Add(&auth.Auth{UID: "u1"})
	reset := time.Now().Add(time.Hour)
	p.CooldownSoftForModel("u1", time.Minute, reset, "glm-5.3", "6004 model rate limit")
	// 该模型：无候选可兜底 → nil（不会白打一次 429）。
	if got := p.PickExcludingForModel(nil, "glm-5.3"); got != nil {
		t.Fatalf("模型级限流窗口内不得再调该模型，got %+v", got)
	}
	// 其他模型：账号本身健康，正常可选。
	if got := p.PickExcludingForModel(nil, "hy3-x"); got == nil || got.UID != "u1" {
		t.Fatalf("其他模型应可选（模型级豁免），got %+v", got)
	}
}

// TestRateLimitedModelsProbing Until 已过、ResetAt 未到 → /status 台账仍出一行并标 Probing。
func TestRateLimitedModelsProbing(t *testing.T) {
	p := New("")
	p.Add(&auth.Auth{UID: "u1"})
	p.SetResetHonorMax(time.Minute)

	reset := time.Now().Add(2 * time.Hour)
	p.mu.Lock()
	p.byUID["u1"].modelCooldowns = map[string]modelCooldown{
		"glm-5.3": {Until: time.Now().Add(-time.Second), ResetAt: reset, Reason: "6004 model rate limit"},
	}
	p.mu.Unlock()

	st, ok := p.Status("u1")
	if !ok {
		t.Fatal("status missing")
	}
	if len(st.RateLimitedModels) != 1 {
		t.Fatalf("网关放行但上游未恢复时台账必须仍在: %+v", st.RateLimitedModels)
	}
	row := st.RateLimitedModels[0]
	if row.Model != "glm-5.3" || row.Kind != "rate_limit" {
		t.Errorf("row = %+v want glm-5.3/rate_limit", row)
	}
	if !row.Probing {
		t.Errorf("Until 已过、ResetAt 未到应标 Probing: %+v", row)
	}
	if row.GatewayCapSec != 60 {
		t.Errorf("gateway_cap_sec = %d want 60（面板据此解释为何提前放行）", row.GatewayCapSec)
	}
	if !row.ResetAt.Equal(reset) {
		t.Errorf("reset_at = %v want %v（必须透出上游权威恢复墙钟）", row.ResetAt, reset)
	}
	// 路由口径不受影响：Until 已过 → 该模型可重试（正是「日志一直 429」的来源）。
	if !p.byUID["u1"].healthyForModel(time.Now(), "glm-5.3") {
		t.Error("Until 已过时 healthyForModel 必须放行（Probing 只改展示，不改选号）")
	}
}

// TestModelCooldownProbingSurvivesPrune 惰性清理只按 displayUntil 删：
// Until 到期时条目必留（台账要展示），ResetAt 到期后才删（不留垃圾）。
func TestModelCooldownProbingSurvivesPrune(t *testing.T) {
	p := New("")
	p.Add(&auth.Auth{UID: "u1"})
	reset := time.Now().Add(time.Hour)
	p.mu.Lock()
	e := p.byUID["u1"]
	e.modelCooldowns = map[string]modelCooldown{
		"glm-5.3": {Until: time.Now().Add(-time.Minute), ResetAt: reset, Reason: "6004 model rate limit"},
	}
	e.pruneExpiredModelCooldowns(time.Now())
	_, kept := e.modelCooldowns["glm-5.3"]
	if !kept {
		t.Fatal("Until 到期但 ResetAt 未到：条目必须保留给台账（不得被清理）")
	}
	// 上游重置墙钟已过 → 真正过期，清理掉（map 不无限膨胀）。
	e.pruneExpiredModelCooldowns(reset.Add(time.Second))
	if _, still := e.modelCooldowns["glm-5.3"]; still {
		t.Error("ResetAt 已过：条目应被清理")
	}
	p.mu.Unlock()
}

// TestModelLockViewProbing 锁池口径：已放行但上游未恢复的号算「不能用」，
// Servable 不得把它当可用证明；解锁时刻取上游重置墙钟。
func TestModelLockViewProbing(t *testing.T) {
	p := lockViewPool(t)
	base := time.Now()
	p.mu.Lock()
	// u1：网关已放行（Until 已过）、上游 2h 后才恢复。
	p.byUID["u1"].modelCooldowns = map[string]modelCooldown{
		"glm-5.3": {Until: base.Add(-time.Second), ResetAt: base.Add(2 * time.Hour), Reason: "6004 model rate limit"},
	}
	// u2：网关锁仍在 1h（正常冷却）。
	p.byUID["u2"].modelCooldowns = map[string]modelCooldown{
		"glm-5.3": {Until: base.Add(time.Hour), ResetAt: base.Add(2 * time.Hour), Reason: "6004 model rate limit"},
	}
	p.mu.Unlock()

	rows := p.ModelLockView()
	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %+v", rows)
	}
	r := rows[0]
	if r.Locked != 2 || r.Probing != 1 {
		t.Errorf("locked/probing = %d/%d want 2/1", r.Locked, r.Probing)
	}
	if r.Servable != 0 {
		t.Errorf("servable = %d want 0（放行≠能服务，请求仍会 429）", r.Servable)
	}
	if r.State != "locked" {
		t.Errorf("state = %q want locked（u2 仍在网关冷却窗口内）", r.State)
	}
	if d := time.Until(r.UnlockAt); d < 110*time.Minute || d > 130*time.Minute {
		t.Errorf("unlock_at 应取 displayUntil（max(Until,ResetAt)=上游重置墙钟≈2h）——"+
			"网关 1h 后放行、2h 后下游才真能用的号，不算「1h 后值得重试」，得到 %v", d)
	}
	if d := time.Until(r.FullyUnlockAt); d < 110*time.Minute || d > 130*time.Minute {
		t.Errorf("fully_unlock_at 应取上游重置墙钟（约 2h），得到 %v", d)
	}

	// 两个号都已放行（只剩上游未恢复）→ 状态 probing，最早/全部解锁都取上游墙钟。
	p.mu.Lock()
	e2 := p.byUID["u2"].modelCooldowns["glm-5.3"]
	e2.Until = base.Add(-time.Second)
	p.byUID["u2"].modelCooldowns["glm-5.3"] = e2
	p.mu.Unlock()

	rows = p.ModelLockView()
	if len(rows) != 1 {
		t.Fatalf("放行后仍应保留一行（上游未恢复）：%+v", rows)
	}
	r = rows[0]
	if r.State != "probing" {
		t.Errorf("state = %q want probing", r.State)
	}
	if r.Servable != 0 || r.Locked != 2 || r.Probing != 2 {
		t.Errorf("servable/locked/probing = %d/%d/%d want 0/2/2", r.Servable, r.Locked, r.Probing)
	}
	if d := time.Until(r.UnlockAt); d < 110*time.Minute || d > 130*time.Minute {
		t.Errorf("probing 下 unlock_at 应取上游重置墙钟（约 2h），得到 %v", d)
	}
}
