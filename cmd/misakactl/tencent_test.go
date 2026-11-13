package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestTencentDesktopEnvelopeRejectsSecretAndEndpointInjection(t *testing.T) {
	for _, request := range []string{
		`{"action":"tencent_describe","cloud":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"tencent_create","cloud":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"tencent_prepare","cloud":{"secret_id":"fixture","secret_key":"sensitive-secret","template":{"id":"fixture","secretKey":"sensitive-secret"}}}`,
	} {
		var output bytes.Buffer
		if run(nil, strings.NewReader(request), &output) != 1 || !json.Valid(output.Bytes()) || strings.Contains(output.String(), "sensitive") || strings.Contains(output.String(), "example.invalid") {
			t.Fatal("invalid cloud request escaped desktop envelope")
		}
	}
}
