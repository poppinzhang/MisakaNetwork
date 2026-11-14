//go:build darwin || linux

package agent

import (
	"os"
	"os/exec"
	"syscall"
)

func startIsolatedProcess(cmd *exec.Cmd) (func(), error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Kill the entire process group, including browser/worker descendants.
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }, nil
}

func runtimeExecutable(info os.FileInfo) bool {
	return info.Mode().IsRegular() && info.Mode()&0111 != 0
}
