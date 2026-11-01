// catchup_test.go 钉住「启动即补跑签到」：关机 / 重启期间错过的时点，启动后补一次。
// 三道门控各有一个用例——签到禁用 / 今天还没有过点 / 账号今天已签，都不得发起签到。
package scheduler

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/linguo2625469/workbuddy2api-panel/internal/auth"
	"github.com/linguo2625469/workbuddy2api-panel/internal/pool"
	"github.com/linguo2625469/workbuddy2api-panel/internal/upstream"
)

// catchupStub 只统计签到 / 余额调用次数；其余端点一律 404（连登管家不做断言，
// 与 TestRunCheckinNowNoLongerTriggersTravel 同口径：错误已被各自路径吞掉）。
type catchupStub struct {
	checkinCalls  atomic.Int32
	resourceCalls atomic.Int32
}

func (c *catchupStub) server() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/daily-checkin"):
			c.checkinCalls.Add(1)
			w.Write([]byte(`{"code":0,"msg":"ok","data":{}}`))
		case strings.HasSuffix(r.URL.Path, "/get-user-resource"):
			c.resourceCalls.Add(1)
			w.Write([]byte(`{"code":0,"data":{"Response":{"Data":{"Accounts":[{"CycleCapacitySize":1000,"CycleCapacityRemain":500,"CycleCapacityUsed":0}]}}}}`))
		default:
			http.NotFound(w, r)
		}
	}))
}

func newCatchupScheduler(t *testing.T, srv *httptest.Server, uids ...string) (*Scheduler, *pool.Pool) {
	t.Helper()
	p := pool.New("")
	for _, uid := range uids {
		p.Add(&auth.Auth{UID: uid, AccessToken: "at", RefreshToken: "rt", ExpiresAt: 9999999999})
	}
	up := &upstream.Client{HTTP: srv.Client(), ChatBaseCN: srv.URL, BillingBaseCN: srv.URL}
	return New(Config{Pool: p, Upstream: up, CheckinHours: []int{9, 21}}), p
}

// todayAt 用今天日期 + 指定时分构造本地时刻（补跑判定按自然日，不能写死日期）。
func todayAt(hour, min int) time.Time {
	n := time.Now()
	return time.Date(n.Year(), n.Month(), n.Day(), hour, min, 0, 0, time.Local)
}

// TestStartupCatchupRunsAfterMissedSlot 09 点已过（10:00 启动）→ 补签一次，
// 并把「今日已签到」落到池里（面板按钮随即显示「已签」）。
func TestStartupCatchupRunsAfterMissedSlot(t *testing.T) {
	stub := &catchupStub{}
	srv := stub.server()
	defer srv.Close()
	s, p := newCatchupScheduler(t, srv, "u1")

	s.startupCatchupAt(todayAt(10, 0))

	if n := stub.checkinCalls.Load(); n != 1 {
		t.Fatalf("daily-checkin calls=%d want 1（09 点已错过应补跑）", n)
	}
	if n := stub.resourceCalls.Load(); n != 1 {
		t.Errorf("get-user-resource calls=%d want 1（补跑签到照常查余额解冻）", n)
	}
	if st, ok := p.Status("u1"); !ok || !st.CheckinDone {
		t.Errorf("补跑后 CheckinDone=%v want true", st.CheckinDone)
	}
}

// TestStartupCatchupSkipsBeforeFirstSlot 08:00 启动 → 今天还没有过点，交给正常排程。
func TestStartupCatchupSkipsBeforeFirstSlot(t *testing.T) {
	stub := &catchupStub{}
	srv := stub.server()
	defer srv.Close()
	s, _ := newCatchupScheduler(t, srv, "u1")

	s.startupCatchupAt(todayAt(8, 0))

	if n := stub.checkinCalls.Load(); n != 0 {
		t.Errorf("daily-checkin calls=%d want 0（09:00 还没到，不该提前打）", n)
	}
}

// TestStartupCatchupSkipsCheckedInAccounts 今天已签的号跳过，只补真漏的号。
func TestStartupCatchupSkipsCheckedInAccounts(t *testing.T) {
	stub := &catchupStub{}
	srv := stub.server()
	defer srv.Close()
	s, p := newCatchupScheduler(t, srv, "done", "missing")
	p.NoteCheckinDone("done")

	s.startupCatchupAt(todayAt(10, 0))

	if n := stub.checkinCalls.Load(); n != 1 {
		t.Errorf("daily-checkin calls=%d want 1（只有 missing 该被补签）", n)
	}
}

// TestStartupCatchupNoopWhenNothingToDo 全部号今天都签过 → 一次上游调用都不发。
func TestStartupCatchupNoopWhenNothingToDo(t *testing.T) {
	stub := &catchupStub{}
	srv := stub.server()
	defer srv.Close()
	s, p := newCatchupScheduler(t, srv, "u1")
	p.NoteCheckinDone("u1")

	s.startupCatchupAt(todayAt(22, 30))

	if n := stub.checkinCalls.Load(); n != 0 {
		t.Errorf("daily-checkin calls=%d want 0", n)
	}
	if n := stub.resourceCalls.Load(); n != 0 {
		t.Errorf("get-user-resource calls=%d want 0（无事可补时不碰上游）", n)
	}
}

// TestStartupCatchupRespectsCheckinDisabled 签到总开关关闭时整段不跑
// （关签到就是关签到，补跑不能绕过它）。
func TestStartupCatchupRespectsCheckinDisabled(t *testing.T) {
	stub := &catchupStub{}
	srv := stub.server()
	defer srv.Close()
	p := pool.New("")
	p.Add(&auth.Auth{UID: "u1", AccessToken: "at", RefreshToken: "rt", ExpiresAt: 9999999999})
	up := &upstream.Client{HTTP: srv.Client(), ChatBaseCN: srv.URL, BillingBaseCN: srv.URL}
	s := New(Config{Pool: p, Upstream: up, CheckinHours: []int{9, 21}, CheckinDisabled: true})

	s.startupCatchupAt(todayAt(10, 0))

	if n := stub.checkinCalls.Load(); n != 0 {
		t.Errorf("daily-checkin calls=%d want 0（checkin_enabled=false 时不得补跑）", n)
	}
}

// TestLatestPassedSlotToday 今日已过时点的判定（补跑时点日志与门控共用）。
func TestLatestPassedSlotToday(t *testing.T) {
	day := func(h, m int) time.Time { return todayAt(h, m) }
	cases := []struct {
		name  string
		now   time.Time
		hours []int
		want  string // "" = 零值
	}{
		{"首个时点前", day(8, 0), []int{9, 21}, ""},
		{"首点之后", day(9, 0), []int{9, 21}, "09:00"},
		{"晚点在整点：含等于", day(21, 0), []int{9, 21}, "21:00"},
		{"两点之间", day(15, 30), []int{9, 21}, "09:00"},
		{"末点之后", day(23, 59), []int{9, 21}, "21:00"},
		{"零点时点", day(0, 30), []int{0, 21}, "00:00"},
	}
	for _, c := range cases {
		got := latestPassedSlotToday(c.now, c.hours)
		if c.want == "" {
			if !got.IsZero() {
				t.Errorf("%s: got %v want 零值", c.name, got.Format("15:04"))
			}
			continue
		}
		if got.Format("15:04") != c.want {
			t.Errorf("%s: got %q want %q", c.name, got.Format("15:04"), c.want)
		}
	}
}
