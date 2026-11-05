package control

import (
	"errors"
	"os"
	"path/filepath"
)

// ProtectPath makes an existing application-owned file or directory private.
// On Windows this replaces the DACL, including inherited access; chmod alone
// only toggles the read-only bit and cannot protect private keys.
func ProtectPath(name string) error {
	if name == "" || !filepath.IsAbs(name) {
		return errors.New("私有文件路径必须为绝对路径")
	}
	info, err := os.Lstat(name)
	if err != nil {
		return err
	}
	if !info.IsDir() && !info.Mode().IsRegular() {
		return errors.New("私有文件路径不能是符号链接或特殊文件")
	}
	return protectPath(name, info.IsDir())
}
