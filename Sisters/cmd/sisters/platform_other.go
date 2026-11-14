//go:build !windows

package main

import (
	"context"
	"errors"

	"github.com/MisakaNetwork/MisakaNetwork/Sisters/agent"
)

func checkPlatform() error { return nil }

func runService(ctx context.Context, c agent.Config, tempDir string) error {
	return errors.New("Windows service mode is unavailable on this platform")
}
