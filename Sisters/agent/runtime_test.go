package agent

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func script(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "runtime")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body+"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRuntimeRequiresValidTerminalResult(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		wantError  bool
	}{
		{"exit_zero", "read -r input\nexit 0", true},
		{"invalid_json", "echo 'cookie: secret'", true},
		{"false", `echo '{"type":"result","ok":false,"error":{"message":"secret"}}'`, true},
		{"nonzero", "echo '{\"type\":\"result\",\"ok\":true,\"data\":{\"status\":\"succeeded\"}}'\nexit 1", true},
		{"duplicate", "echo '{\"type\":\"result\",\"ok\":true}'\necho '{\"type\":\"result\",\"ok\":true}'", true},
		{"success", `echo '{"type":"progress","stage":"ordering","message":"cookie secret"}'
echo '{"type":"result","ok":true,"data":{"status":"succeeded","order_id":"private"}}'`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := executableRunner{path: script(t, tc.body)}
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
		{`echo '{"type":"result","ok":true,"data":{"version":"` + Version + `","protocol":1,"ready":true,"bili_version":"2.15.17"}}'`, true},
		{`echo '{"type":"result","ok":true,"data":{"version":"` + Version + `","protocol":2,"ready":true,"bili_version":"2.15.17"}}'`, false},
		{`echo '{"type":"result","ok":true,"data":{"version":"` + Version + `","protocol":1,"ready":false,"bili_version":"2.15.17"}}'`, false},
		{`echo '{"type":"result","ok":true,"data":{"version":"` + Version + `","protocol":1,"ready":true,"bili_version":"private account"}}'`, false},
		{`echo '{"type":"result","ok":true,"data":{"version":"0.1.0","protocol":1,"ready":true,"bili_version":"2.15.17"}}'`, false},
		{`echo '{"type":"result","ok":true,"data":{"protocol":1,"ready":true,"bili_version":"2.15.17"}}'`, false},
		{"exit 0", false},
	} {
		r := executableRunner{path: script(t, tc.body)}
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
	r := executableRunner{path: script(t, "sleep 60 &\nwait")}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := r.run(ctx, []byte("{}\n"), nil); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled process succeeded")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("process descendants survived cancellation")
	}
}
