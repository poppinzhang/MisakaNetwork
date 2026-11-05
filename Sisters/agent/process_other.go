//go:build !darwin && !linux

package agent

import "os/exec"

func isolateProcess(cmd *exec.Cmd) {}
