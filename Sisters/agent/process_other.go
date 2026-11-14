//go:build !darwin && !linux && !windows

package agent

import (
	"errors"
	"os"
	"os/exec"
)

func startIsolatedProcess(cmd *exec.Cmd) (func(), error) {
	return nil, errors.New("unsupported runtime platform")
}

func runtimeExecutable(info os.FileInfo) bool { return false }
