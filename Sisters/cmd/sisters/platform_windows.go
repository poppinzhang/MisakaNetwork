package main

import (
	"errors"
	"runtime"

	"golang.org/x/sys/windows"
)

func checkPlatform() error {
	return checkWindowsVersion(windows.RtlGetVersion().MajorVersion, runtime.GOARCH)
}

func checkWindowsVersion(major uint32, arch string) error {
	if major < 10 || arch != "amd64" {
		return errors.New("Sisters requires Windows 10 or later on x64")
	}
	return nil
}
