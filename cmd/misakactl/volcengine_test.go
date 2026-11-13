package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestVolcengineDesktopEnvelopeRejectsSecretAndEndpointInjection(t *testing.T) {
	for _, request := range []string{
		`{"action":"volcengine_zones","volcengine":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"volcengine_zones","volcengine":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"volcengine_network_lookup","volcengine":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"volcengine_network_create","volcengine":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"volcengine_describe","volcengine":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"volcengine_create","volcengine":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"volcengine_prepare","volcengine":{"secret_id":"fixture","secret_key":"sensitive-secret","template":{"id":"fixture","secretKey":"sensitive-secret"}}}`,
	} {
		var output bytes.Buffer
		if run(nil, strings.NewReader(request), &output) != 1 || !json.Valid(output.Bytes()) || strings.Contains(output.String(), "sensitive") || strings.Contains(output.String(), "example.invalid") {
			t.Fatal("invalid cloud request escaped desktop envelope")
		}
	}
}
