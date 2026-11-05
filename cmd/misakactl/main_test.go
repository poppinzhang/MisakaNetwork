package main

import (
	"bytes"
	"encoding/json"
	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
	"strings"
	"testing"
)

func TestCommandStrictJSONAndVersion(t *testing.T) {
	var out bytes.Buffer
	if code := run([]string{"--version"}, strings.NewReader(""), &out); code != 0 || strings.TrimSpace(out.String()) != control.Version {
		t.Fatal("version failed")
	}
	for _, input := range []string{`{"action":"init_pki"} {}`, `{"private":"sensitive"}`, strings.Repeat("x", 1<<20+1), `{"action":"unknown"}`, `{"action":"deploy","password":"sensitive"}`} {
		out.Reset()
		if code := run(nil, strings.NewReader(input), &out); code != 1 {
			t.Fatal("invalid request accepted")
		}
		if !json.Valid(out.Bytes()) || strings.Contains(out.String(), "sensitive") {
			t.Fatal("error is not safe JSON")
		}
	}
}
