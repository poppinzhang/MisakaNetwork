package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

func TestCLI(t *testing.T) {
	for _, tc := range []struct {
		args     []string
		code     int
		contains string
	}{{[]string{"--version"}, 0, "0.3.2"}, {nil, 2, "Usage"}, {[]string{"serve"}, 2, "Usage"}, {[]string{"serve", "--unknown", "secret"}, 2, "Usage"}, {[]string{"serve", "--config", "/nonexistent/private/path"}, 1, "cannot open agent configuration"}} {
		var out, errOut bytes.Buffer
		if code := run(context.Background(), tc.args, &out, &errOut); code != tc.code {
			t.Fatalf("exit=%d want=%d", code, tc.code)
		}
		text := out.String() + errOut.String()
		if !strings.Contains(text, tc.contains) || strings.Contains(text, "secret") || strings.Contains(text, "private/path") {
			t.Fatalf("unexpected output: %q", text)
		}
	}
}
