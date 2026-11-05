//go:build !windows

package control

import "os"

func protectPath(name string, directory bool) error {
	mode := os.FileMode(0600)
	if directory {
		mode = 0700
	}
	return os.Chmod(name, mode)
}
