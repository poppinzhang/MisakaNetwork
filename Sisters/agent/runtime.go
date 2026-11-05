package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"time"
)

type progress struct {
	Status           string `json:"status"`
	Stage            string `json:"stage"`
	AttemptCurrent   int    `json:"attempt_current"`
	AttemptTotal     int    `json:"attempt_total"`
	CountdownSeconds *int   `json:"countdown_seconds"`
}
type result struct {
	RuntimeVersion string `json:"version"`
	Status         string `json:"status"`
	Version        string `json:"bili_version"`
	Protocol       int    `json:"protocol"`
	Ready          bool   `json:"ready"`
}
type frame struct {
	Type string `json:"type"`
	OK   bool   `json:"ok"`
	progress
	Data result `json:"data"`
}
type runner interface {
	probe(context.Context) (string, error)
	run(context.Context, []byte, func(progress)) (result, error)
}
type executableRunner struct{ path string }

var safeVersion = regexp.MustCompile(`^[a-zA-Z0-9._+\-]{1,64}$`)

func (r executableRunner) probe(ctx context.Context) (string, error) {
	info, err := os.Stat(r.path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
		return "", errors.New("runtime executable unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	data, err := r.invoke(ctx, []byte("{\"op\":\"ping\"}\n"), nil)
	if err != nil || !data.Ready || data.Protocol != 1 || data.RuntimeVersion != Version || !safeVersion.MatchString(data.Version) {
		return "", errors.New("runtime readiness check failed")
	}
	return data.Version, nil
}

func (r executableRunner) run(ctx context.Context, input []byte, emit func(progress)) (result, error) {
	return r.invoke(ctx, input, emit)
}

func (r executableRunner) invoke(ctx context.Context, input []byte, emit func(progress)) (result, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := exec.CommandContext(ctx, r.path)
	isolateProcess(cmd)
	cmd.WaitDelay = 2 * time.Second
	cmd.Stdin = bytes.NewReader(input)
	cmd.Stderr = io.Discard // Runtime output may contain cookies or account information.
	out, err := cmd.StdoutPipe()
	if err != nil {
		return result{}, errors.New("cannot open runtime output")
	}
	if err := cmd.Start(); err != nil {
		return result{}, errors.New("cannot start runtime")
	}
	scanner := bufio.NewScanner(out)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	var terminal *frame
	var protocolErr bool
	for scanner.Scan() {
		var f frame
		if err := json.Unmarshal(scanner.Bytes(), &f); err != nil {
			protocolErr = true
			cancel()
			break
		}
		switch f.Type {
		case "progress":
			if terminal != nil {
				protocolErr = true
				cancel()
				break
			}
			if emit != nil {
				emit(f.progress)
			}
		case "result":
			if terminal != nil {
				protocolErr = true
				cancel()
				break
			}
			terminal = &f
		default:
			protocolErr = true
			cancel()
		}
		if protocolErr {
			break
		}
	}
	if scanner.Err() != nil {
		protocolErr = true
		cancel()
	}
	waitErr := cmd.Wait()
	if ctx.Err() != nil || waitErr != nil || protocolErr || terminal == nil || !terminal.OK {
		return result{}, errors.New("runtime failed or returned an invalid result")
	}
	return terminal.Data, nil
}

// stageMessages covers every stage code runtime/bridge.py emits.
var stageMessages = map[string]string{
	"starting":     "正在启动抢票工具",
	"waiting":      "等待开票时间",
	"preparing":    "正在准备订单",
	"ordering":     "正在尝试创建订单",
	"ordered":      "抢票工具已报告下单成功，正在确认结果",
	"page_timeout": "购票页长时间未开放购买，抢票工具已停止",
}

var statusMessages = map[string]string{
	"succeeded":       "抢票工具已报告下单成功，正在确认结果",
	"duplicate_order": "抢票工具检测到已有订单，正在确认结果",
	"failed":          "抢票工具报告执行异常",
	"cooldown":        "请求过于频繁，正在等待冷却",
}

// progressText returns a fixed event for history and a status line that may
// add the countdown or attempt. Only fixed text and bridge-checked integers
// cross the gRPC boundary; a per-second countdown never adds events.
func progressText(p progress) (event, line string) {
	if p.Stage != "page_timeout" {
		if message, ok := statusMessages[p.Status]; ok {
			return message, message
		}
	}
	event, ok := stageMessages[p.Stage]
	if !ok {
		return "抢票任务执行中", "抢票任务执行中"
	}
	switch {
	case p.Stage == "waiting" && p.CountdownSeconds != nil:
		return event, event + "，剩余 " + remaining(*p.CountdownSeconds)
	case (p.Stage == "preparing" || p.Stage == "ordering") && p.AttemptCurrent > 0 && p.AttemptTotal > 0:
		return event, fmt.Sprintf("%s（第 %d/%d 次）", event, p.AttemptCurrent, p.AttemptTotal)
	}
	return event, event
}

func remaining(seconds int) string {
	switch {
	case seconds >= 3600:
		return fmt.Sprintf("%d 小时 %d 分", seconds/3600, seconds%3600/60)
	case seconds >= 60:
		return fmt.Sprintf("%d 分 %d 秒", seconds/60, seconds%60)
	}
	return fmt.Sprintf("%d 秒", seconds)
}
