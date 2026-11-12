//go:build !windows

package control

import (
	"os"

	"golang.org/x/sys/unix"
)

func lockPKIFile(file *os.File) error {
	return unix.Flock(int(file.Fd()), unix.LOCK_EX)
}
