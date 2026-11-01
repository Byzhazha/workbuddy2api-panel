package pool

// sticky_expiring_test.go 钉住「粘性路径也要服从快到期优先」这条改动。
//
// 背景：会话粘性直接按 uid 取号（PickByUIDForModel），完全绕过 pickWeighted 的
// 加权抽签，于是 prefer_expiring 对粘性会话等于不存在。实测（2026-11，4 号池）：
// 两个 2199 分的号当天各只接 2 个请求，而它们 11-30 各有 1699 分到期 —— 流量全压
// 在不过期的 6000+/7000+ 分号上。
//
// 判据：粘性号自己**没有**快过期批次 + 池里**此刻就有一个能接手**（healthyForModel
// 且未占满在途）的快过期号 → 返回 nil 让 handler 解绑换号。三条反向边界同样要钉住，
// 否则会退化成「每个请求都解绑重绑」的抖动。

import (
	"log"
	"math/rand/v2"
	"strings"
	"testing"
	"time"

	"github.com/linguo2625469/workbuddy2api-panel/internal/auth"
)

// stickyExpiringPool 构造「粘性号不过期 + 对端快过期」的两人池。
func stickyExpiringPool(t *testing.T) *Pool {
	t.Helper()
	p := New("")
	p.Add(&auth.Auth{UID: "sticky"})
	p.Add(&auth.Auth{UID: "expiring"})
	p.SetCreditsDetailed("sticky", 5000, 5000, 0, time.Time{}, 0)
	p.SetCreditsDetailed("expiring", 2000, 2000, 1800, time.Now().Add(24*time.Hour), 1800)
	return p
}

// TestStickyYieldsToExpiringPeer 主路径：粘性号不过期、对端可接手 → 让位。
func TestStickyYieldsToExpiringPeer(t *testing.T) {
	p := stickyExpiringPool(t)
	if got := p.PickByUIDForModel("sticky", "m"); got != nil {
		t.Fatalf("粘性号无快过期批次、对端可接手 → 应返回 nil 让 handler 解绑，got %s", got.UID)
	}
	// 让位只影响「取不取这个号」，不得改动它的余额/冷却状态。
	st, ok := p.Status("sticky")
	if !ok || st.Credits != 5000 || st.Cooling {
		t.Fatalf("让位不应改动粘性号状态: %+v", st)
	}
	// 同一请求经普通轮换必须还能选到号（否则 handler 会 503 而不是换号）。
	if got := p.Pick(); got == nil {
		t.Fatal("让位后普通轮换应仍有可用账号")
	}
}

// TestStickyNoYieldWhenPreferExpiringDisabled 关闭开关 → 完全恢复旧行为。
func TestStickyNoYieldWhenPreferExpiringDisabled(t *testing.T) {
	p := stickyExpiringPool(t)
	p.SetPreferExpiring(false)
	got := p.PickByUIDForModel("sticky", "m")
	if got == nil || got.UID != "sticky" {
		t.Fatalf("prefer_expiring=false 不应让位，got %v", got)
	}
}

// TestStickyNoYieldWhenStickyItselfExpiring 粘性号自己更紧迫（差距不到 2 倍）→ 不必搬。
func TestStickyNoYieldWhenStickyItselfExpiring(t *testing.T) {
	p := stickyExpiringPool(t)
	// sticky：4000/5000 在 1 小时后到期 → 0.8/2 = 0.4；对端仍 0.45 → 不够 2 倍，不搬。
	p.SetCreditsDetailed("sticky", 5000, 5000, 4000, time.Now().Add(time.Hour), 4000)
	got := p.PickByUIDForModel("sticky", "m")
	if got == nil || got.UID != "sticky" {
		t.Fatalf("两边紧迫度接近时不应让位（否则就是抖动），got %v", got)
	}
}

// TestStickyKeepsWhenUrgencyComparable 紧迫度只差一点（< urgencyYieldRatio 倍）→ 不搬：
// 用户要的是「谁更该花就多给谁」，不是「谁早一天就独占」，权重层面的倾斜已经够了。
func TestStickyKeepsWhenUrgencyComparable(t *testing.T) {
	p := stickyExpiringPool(t)
	// sticky：800/1000 在 24h 后到期 → 0.8/2 = 0.4；对端 0.9/2 = 0.45。
	p.SetCreditsDetailed("sticky", 1000, 1000, 800, time.Now().Add(24*time.Hour), 800)
	if got := p.PickByUIDForModel("sticky", "m"); got == nil || got.UID != "sticky" {
		t.Fatalf("紧迫度接近不应让位，got %v", got)
	}
	// 对端改成压倒性紧迫（0.9/1 ≈ 0.9 ≥ 0.4×2 = 0.8）→ 这时才让位。
	p.SetCreditsDetailed("expiring", 2000, 2000, 1800, time.Now().Add(time.Minute), 1800)
	if got := p.PickByUIDForModel("sticky", "m"); got != nil {
		t.Fatalf("对端紧迫度 ≥2 倍时应让位，got %s", got.UID)
	}
}

// TestUrgencyWeightBalancedOnRealPool 用线上真实快照（2026-11-01，4 号）钉住
// 「明显倾斜但不独占」：紧迫度高的号拿到更多流量，但没有任何号被饿死。
//
// 数据取自 /status：2478 分 10.8 天后到期 / 2295 分 20.9 天后 / 1699 分 28.6 天后 ×2。
func TestUrgencyWeightBalancedOnRealPool(t *testing.T) {
	withNoPickGap(t)
	now := time.Now()
	day := 24 * time.Hour
	build := func() *Pool {
		p := New("")
		for _, uid := range []string{"main", "mid", "soonA", "soonB"} {
			p.Add(&auth.Auth{UID: uid})
		}
		snap := func(uid string, credits, e1 int64, d1 time.Duration, e2 int64, d2 time.Duration) {
			p.SetCreditsSnapshot(uid, CreditsSnapshot{
				Remain: credits, Total: credits,
				ExpiryBuckets: []ExpiryBucket{
					{Date: now.Add(d1).Format("2006-01-02"), ExpireAt: now.Add(d1), Remain: e1},
					{Date: now.Add(d2).Format("2006-01-02"), ExpireAt: now.Add(d2), Remain: e2},
				},
			})
		}
		snap("main", 7365, 2478, 11*day, 4887, 30*day)
		snap("mid", 6132, 2295, 21*day, 3837, 26*day)
		snap("soonA", 2199, 1699, 29*day, 500, 3600*day)
		snap("soonB", 2199, 1699, 29*day, 500, 3600*day)
		return p
	}

	dist := func(p *Pool) map[string]int {
		rng := rand.New(rand.NewPCG(7, 11))
		p.SetRandomSource(func(n int64) int64 { return rng.Int64N(n) })
		counts := map[string]int{}
		for i := 0; i < 4000; i++ {
			got := p.Pick()
			if got == nil {
				t.Fatal("pick returned nil")
			}
			counts[got.UID]++
		}
		return counts
	}

	on := dist(build())

	off := build()
	off.SetPreferExpiring(false)
	base := dist(off)

	share := func(m map[string]int, uid string) float64 {
		return float64(m[uid]) / 4000
	}
	// 倾斜：两个 1699 分的号（占比 77%、29 天后到期）份额必须上升；而紧迫度最弱的
	// mid（占比 37%、21 天后到期）与靠积分基数取胜的 main 都应让出一部分流量。
	//
	// main 份额下降不是回归：旧口径就是"积分多的号拿最多"，紧迫项的全部意义就是把它
	// 从 38% 压到 30%、把被闲置的两个 2199 分号从 15% 抬到 25% —— 这是"均衡"的定义。
	for _, uid := range []string{"soonA", "soonB"} {
		if share(on, uid) <= share(base, uid) {
			t.Errorf("%s 开启紧迫项后份额应上升：%.3f vs %.3f", uid, share(on, uid), share(base, uid))
		}
	}
	for _, uid := range []string{"main", "mid"} {
		if share(on, uid) >= share(base, uid) {
			t.Errorf("%s 应让出部分流量给更紧迫的号：%.3f vs %.3f", uid, share(on, uid), share(base, uid))
		}
	}
	// 均衡：没有任何号被独占（<=45%），也没有任何号被饿死（>=5%）。
	for uid, n := range on {
		s := float64(n) / 4000
		if s > 0.45 {
			t.Errorf("%s 份额 %.3f 过高（应为倾斜而非独占）", uid, s)
		}
		if s < 0.05 {
			t.Errorf("%s 份额 %.3f 过低（应保留基本流量）", uid, s)
		}
	}
	// 紧迫度较弱的 mid（21 天后到期、占比 37%）不该被两个 1699 分的号压死。
	if share(on, "soonA") <= share(on, "mid") {
		t.Errorf("soonA(29天/77%%占比) 份额应高于 mid：%.3f vs %.3f", share(on, "soonA"), share(on, "mid"))
	}
	t.Logf("开启=%v 关闭=%v", on, base)
}

// TestUrgencyNoiseFloor 噪声级紧迫度不推动路由：对端只有一丁点远期积分时，
// 即使粘性号完全没有到期压力也不让位（否则会为 2027 年才到期的 1 分反复重绑）。
func TestUrgencyNoiseFloor(t *testing.T) {
	p := New("")
	p.Add(&auth.Auth{UID: "sticky"})
	p.Add(&auth.Auth{UID: "tiny"})
	p.SetCreditsDetailed("sticky", 5000, 5000, 0, time.Time{}, 0)
	// 1/100000 占比、300 天后到期 → 约 3.3e-8，远低于 urgencyNoiseFloor。
	p.SetCreditsDetailed("tiny", 100_000, 100_000, 1, time.Now().Add(300*24*time.Hour), 1)
	if got := p.PickByUIDForModel("sticky", "m"); got == nil || got.UID != "sticky" {
		t.Fatalf("噪声级紧迫度不应推动让位，got %v", got)
	}
}

// TestStickyNoYieldWhenPeerCooling 对端冷却中 → 让位只会白抖一次（解绑后选不到它），
// 必须原地放行。
func TestStickyNoYieldWhenPeerCooling(t *testing.T) {
	p := stickyExpiringPool(t)
	p.Cooldown("expiring", CoolHard, time.Hour, "14018 credits exhausted")
	got := p.PickByUIDForModel("sticky", "m")
	if got == nil || got.UID != "sticky" {
		t.Fatalf("对端冷却中不应让位，got %v", got)
	}
}

// TestStickyNoYieldWhenPeerModelCooled 对端被模型级冷却（账号整体健康）→ 同理放行：
// 判据必须带 healthyForModel，否则会拿一个当前模型根本不可用的号来换。
func TestStickyNoYieldWhenPeerModelCooled(t *testing.T) {
	p := stickyExpiringPool(t)
	p.CooldownSoftForModel("expiring", time.Minute, time.Now().Add(time.Hour), "m", "6004 model rate limit")

	got := p.PickByUIDForModel("sticky", "m")
	if got == nil || got.UID != "sticky" {
		t.Fatalf("对端该模型不可用不应让位，got %v", got)
	}
	// 换个模型（未被冷却）→ 又应该让位。
	if got := p.PickByUIDForModel("sticky", "other-model"); got != nil {
		t.Fatalf("对端在另一个模型上可用，应让位，got %s", got.UID)
	}
}

// TestStickyNoYieldWhenPeerInFlightFull 对端占满在途名额 → 放行。
func TestStickyNoYieldWhenPeerInFlightFull(t *testing.T) {
	p := stickyExpiringPool(t)
	p.SetMaxInFlight(1)
	if !p.Acquire("expiring") {
		t.Fatal("acquire expiring failed")
	}
	if got := p.PickByUIDForModel("sticky", "m"); got == nil || got.UID != "sticky" {
		t.Fatalf("对端在途已满不应让位，got %v", got)
	}
}

// TestStickyKeepsWhenNoExpiringPeer 池里没有任何快过期号 → 纯旧行为，不引入抖动。
func TestStickyKeepsWhenNoExpiringPeer(t *testing.T) {
	p := New("")
	p.Add(&auth.Auth{UID: "a"})
	p.Add(&auth.Auth{UID: "b"})
	p.SetCreditsDetailed("a", 100, 100, 0, time.Time{}, 0)
	p.SetCreditsDetailed("b", 100, 100, 0, time.Time{}, 0)
	got := p.PickByUIDForModel("a", "m")
	if got == nil || got.UID != "a" {
		t.Fatalf("无快过期号时应保持粘性，got %v", got)
	}
}

// TestStickyResumesWhenPeerExpiringGone 对端的快过期批次被消耗光（expiring=0）后，
// 让位条件不再成立——避免「号已经花完还一直被让位」的钝化。
func TestStickyResumesWhenPeerExpiringGone(t *testing.T) {
	p := stickyExpiringPool(t)
	// 快过期批次被消耗光后（expiring=0），让位条件不再成立。
	p.SetCreditsDetailed("expiring", 200, 200, 0, time.Time{}, 0)
	got := p.PickByUIDForModel("sticky", "m")
	if got == nil || got.UID != "sticky" {
		t.Fatalf("对端快过期批次耗尽后不应再让位，got %v", got)
	}
}

// TestStickyYieldLogThrottled 让位日志必须节流：该分支在窗口期内每个请求都命中，
// 而运行日志环只有 500 行——不限流会把任务/对话日志整个刷掉。
func TestStickyYieldLogThrottled(t *testing.T) {
	p := stickyExpiringPool(t)

	var buf strings.Builder
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)

	for i := 0; i < 5; i++ {
		if got := p.PickByUIDForModel("sticky", "m"); got != nil {
			t.Fatalf("第 %d 次应让位，got %s", i, got.UID)
		}
	}
	if n := strings.Count(buf.String(), "prefer_expiring"); n != 1 {
		t.Fatalf("5 次让位应只留 1 条日志（5 分钟节流），got %d 条:\n%s", n, buf.String())
	}
}
