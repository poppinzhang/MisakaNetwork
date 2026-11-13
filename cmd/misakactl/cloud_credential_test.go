package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestCredentialDesktopEnvelopeRejectsUnsafeRequests(t *testing.T) {
	for _, request := range []string{
		`{"action":"verify_cloud_credential"}`,
		`{"action":"verify_cloud_credential","cloud_credential":{"provider":"tencent","access_key_id":"fixture-id","access_key_secret":"fixture-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"verify_cloud_credential","cloud_credential":{"provider":"aliyun","access_key_id":"fixture-id","access_key_secret":"fixture-secret","action":"RunInstances"}}`,
		`{"action":"verify_cloud_credential","cloud_credential":{"provider":"volcengine","access_key_id":"bad\nheader","access_key_secret":"fixture-secret"}}`,
	} {
		var output bytes.Buffer
		if run(nil, strings.NewReader(request), &output) != 1 || !json.Valid(output.Bytes()) || strings.Contains(output.String(), "fixture") || strings.Contains(output.String(), "example.invalid") {
			t.Fatal("invalid credential request escaped desktop envelope")
		}
	}
}
