package agent

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestRuntimeRequiresValidTerminalResult(t *testing.T) {
	for _, tc := range []struct {
		name      string
		fixture   runtimeFixture
		wantError bool
	}{
		{"exit_zero", runtimeFixture{}, true},
		{"invalid_json", runtimeFixture{Frames: []string{"cookie: secret"}}, true},
		{"false", runtimeFixture{Frames: []string{`{"type":"result","ok":false,"error":{"message":"secret"}}`}}, true},
		{"nonzero", runtimeFixture{Frames: []string{`{"type":"result","ok":true,"data":{"status":"succeeded"}}`}, ExitCode: 1}, true},
		{"duplicate", runtimeFixture{Frames: []string{`{"type":"result","ok":true}`, `{"type":"result","ok":true}`}}, true},
		{"progress_after_result", runtimeFixture{Frames: []string{`{"type":"result","ok":true,"data":{"status":"succeeded","order_id":"12"}}`, `{"type":"progress","status":"succeeded"}`}}, true},
		{"success", runtimeFixture{Frames: []string{`{"type":"progress","stage":"ordering","message":"cookie secret"}`, `{"type":"result","ok":true,"data":{"status":"succeeded","order_id":"private"}}`}}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := fixtureRunner(t, tc.fixture)
			out, err := r.run(context.Background(), []byte("{}\n"), func(p progress) {
				if event, line := progressText(p); strings.Contains(event+line, "secret") {
					t.Fatal("unsafe progress")
				}
			})
			if (err != nil) != tc.wantError {
				t.Fatalf("result=%v error=%v", out, err)
			}
			if err != nil && strings.Contains(err.Error(), "secret") {
				t.Fatal("raw output leaked")
			}
		})
	}
}

func TestEveryBridgeStageHasAMessage(t *testing.T) {
	// The bridge and Sisters share this vocabulary across languages, so check
	// the codes the bridge actually emits rather than a copy of them.
	source, err := os.ReadFile(filepath.Join("..", "..", "runtime", "bridge.py"))
	if err != nil {
		t.Fatal(err)
	}
	block := regexp.MustCompile(`(?s)STAGE_CODES = \{(.*?)\n\}`).FindSubmatch(source)
	if block == nil {
		t.Fatal("STAGE_CODES not found in bridge.py")
	}
	codes := regexp.MustCompile(`:\s*"([a-z_]+)"`).FindAllSubmatch(block[1], -1)
	if len(codes) == 0 {
		t.Fatal("no stage codes found in bridge.py")
	}
	for _, code := range codes {
		if _, ok := stageMessages[string(code[1])]; !ok {
			t.Errorf("bridge stage %q has no Sisters message", code[1])
		}
	}
}

func TestProgressTextUsesBridgeCodes(t *testing.T) {
	seconds := 3725
	for _, tc := range []struct {
		p           progress
		event, line string
	}{
		{progress{Status: "running", Stage: "waiting", CountdownSeconds: &seconds}, "等待开票时间", "等待开票时间，剩余 1 小时 2 分"},
		{progress{Status: "running", Stage: "ordering", AttemptCurrent: 3, AttemptTotal: 20}, "正在尝试创建订单", "正在尝试创建订单（第 3/20 次）"},
		{progress{Status: "cooldown", Stage: "ordering", AttemptCurrent: 3, AttemptTotal: 20}, "请求过于频繁，正在等待冷却", "请求过于频繁，正在等待冷却"},
		{progress{Status: "failed", Stage: "page_timeout"}, "购票页长时间未开放购买，抢票工具已停止", "购票页长时间未开放购买，抢票工具已停止"},
		{progress{Status: "succeeded", Stage: "ordered", AttemptCurrent: 1, AttemptTotal: 20}, "抢票工具已报告下单成功，正在确认结果", "抢票工具已报告下单成功，正在确认结果"},
		{progress{Status: "running", Stage: "working"}, "抢票任务执行中", "抢票任务执行中"},
	} {
		if event, line := progressText(tc.p); event != tc.event || line != tc.line {
			t.Errorf("%+v: got %q / %q", tc.p, event, line)
		}
	}
}

func TestRuntimeProbeChecksDependencyReadiness(t *testing.T) {
	for _, tc := range []struct {
		body  string
		ready bool
	}{
		{`{"type":"result","ok":true,"data":{"version":"` + Version + `","protocol":1,"ready":true,"bili_version":"2.15.18"}}`, true},
		{`{"type":"result","ok":true,"data":{"version":"` + Version + `","protocol":2,"ready":true,"bili_version":"2.15.18"}}`, false},
		{`{"type":"result","ok":true,"data":{"version":"` + Version + `","protocol":1,"ready":false,"bili_version":"2.15.18"}}`, false},
		{`{"type":"result","ok":true,"data":{"version":"` + Version + `","protocol":1,"ready":true,"bili_version":"private account"}}`, false},
		{`{"type":"result","ok":true,"data":{"version":"0.1.0","protocol":1,"ready":true,"bili_version":"2.15.18"}}`, false},
		{`{"type":"result","ok":true,"data":{"protocol":1,"ready":true,"bili_version":"2.15.18"}}`, false},
		{"", false},
	} {
		r := fixtureRunner(t, runtimeFixture{Frames: []string{tc.body}})
		_, err := r.probe(context.Background())
		if (err == nil) != tc.ready {
			t.Fatalf("ready=%v error=%v", tc.ready, err)
		}
	}
	r := executableRunner{path: filepath.Join(t.TempDir(), "missing")}
	if _, err := r.probe(context.Background()); err == nil {
		t.Fatal("missing executable ready")
	}
}

func TestRuntimeCancellationKillsProcessGroup(t *testing.T) {
	// A child holds stdout open after its parent dies. Cancellation must kill
	// descendants too, otherwise scanner.Scan remains blocked indefinitely.
	marker := filepath.Join(t.TempDir(), "child-ready")
	r := fixtureRunner(t, runtimeFixture{Child: true, Wait: true, ChildMarker: marker})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := r.run(ctx, []byte("{}\n"), nil); done <- err }()
	waitRuntimeMarker(t, marker)
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled process succeeded")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("process descendants survived cancellation")
	}
}

func waitRuntimeMarker(t *testing.T, marker string) uint32 {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		// WriteFile creates the marker before writing its PID. Wait for its
		// contents, and return that validated value instead of rereading it.
		if data, err := os.ReadFile(marker); err == nil {
			if pid, err := strconv.ParseUint(string(data), 10, 32); err == nil && pid > 0 {
				return uint32(pid)
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("runtime helper did not start")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestRuntimeCleansDescendantsAfterParentExit(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "child-ready")
	r := fixtureRunner(t, runtimeFixture{Child: true, ChildMarker: marker, Frames: []string{`{"type":"result","ok":true,"data":{"status":"completed"}}`}})
	done := make(chan error, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go func() { _, err := r.run(ctx, []byte("{}\n"), nil); done <- err }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("normal runtime exit failed: %v", err)
		}
		if _, err := os.Stat(marker); err != nil {
			t.Fatal("descendant never started")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("normal runtime exit left a descendant holding stdout")
	}
}

func TestRuntimeCancellationDuringStart(t *testing.T) {
	r := fixtureRunner(t, runtimeFixture{Child: true, Wait: true})
	for i := 0; i < 20; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { _, err := r.run(ctx, []byte("{}\n"), nil); done <- err }()
		if i%2 == 0 {
			time.Sleep(time.Millisecond)
		}
		cancel()
		select {
		case err := <-done:
			if err == nil {
				t.Fatal("cancelled runtime succeeded")
			}
		case <-time.After(3 * time.Second):
			t.Fatal("cancellation raced past process isolation")
		}
	}
}

func TestRuntimeReadsPaymentOnlyFromFinalResult(t *testing.T) {
	r := fixtureRunner(t, runtimeFixture{Frames: []string{`{"type":"progress","status":"succeeded","order_id":"99","payment_code_url":"https://evil.test","message":"private payment"}`, `{"type":"result","ok":true,"data":{"status":"succeeded","order_id":"12","order_detail_url":"https://show.bilibili.com/platform/orderDetail.html?order_id=12","payment_code_url":"weixin://wxpay/bizpayurl?pr=synthetic_token"}}`}})
	out, err := r.run(context.Background(), []byte("{}\n"), func(p progress) {
		if event, line := progressText(p); strings.Contains(event+line, "private") || strings.Contains(event+line, "https://") {
			t.Fatal("payment fields leaked from progress")
		}
	})
	if err != nil || out.OrderID != "12" || out.PaymentCodeURL != testPaymentCode || out.OrderDetailURL != "https://show.bilibili.com/platform/orderDetail.html?order_id=12" {
		t.Fatalf("final payment not parsed: %v", err)
	}
}

func TestRuntimeFinalOrderSurvivesLateCancellation(t *testing.T) {
	for _, tc := range []struct {
		name, frames string
		wantSuccess  bool
	}{
		{"success", `{"type":"result","ok":true,"data":{"status":"succeeded","order_id":"12","payment_code_url":"weixin://wxpay/bizpayurl?pr=synthetic_token"}}`, true},
		{"duplicate", `{"type":"result","ok":true,"data":{"status":"duplicate_order","order_id":"12"}}`, true},
		{"progress_only", `{"type":"progress","status":"succeeded"}`, false},
		{"completed", `{"type":"result","ok":true,"data":{"status":"completed","order_id":"12"}}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// This marker contains no business data; it establishes that all
			// stdout frames have been written before cancellation is requested.
			marker := filepath.Join(t.TempDir(), "ready")
			r := fixtureRunner(t, runtimeFixture{Frames: []string{tc.frames}, Marker: marker, Wait: true})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			type outcome struct {
				out result
				err error
			}
			done := make(chan outcome, 1)
			go func() { out, err := r.run(ctx, []byte("{}\n"), nil); done <- outcome{out, err} }()
			deadline := time.Now().Add(3 * time.Second)
			for {
				if _, err := os.Stat(marker); err == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("runtime did not emit test frames")
				}
				time.Sleep(time.Millisecond)
			}
			cancel()
			select {
			case got := <-done:
				if (got.err == nil) != tc.wantSuccess {
					t.Fatalf("late cancellation success=%v error=%v", tc.wantSuccess, got.err)
				}
				if tc.wantSuccess && got.out.OrderID != "12" {
					t.Fatal("confirmed order was lost")
				}
			case <-time.After(3 * time.Second):
				t.Fatal("runtime did not stop after cancellation")
			}
		})
	}
}
