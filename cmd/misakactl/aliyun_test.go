package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestAliyunDesktopEnvelopeRejectsSecretAndEndpointInjection(t *testing.T) {
	for _, request := range []string{
		`{"action":"aliyun_zones","aliyun":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"aliyun_zones","aliyun":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"aliyun_network_lookup","aliyun":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"aliyun_network_create","aliyun":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"aliyun_describe","aliyun":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"aliyun_create","aliyun":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"aliyun_prepare","aliyun":{"secret_id":"fixture","secret_key":"sensitive-secret","template":{"id":"fixture","secretKey":"sensitive-secret"}}}`,
	} {
		var output bytes.Buffer
		if run(nil, strings.NewReader(request), &output) != 1 || !json.Valid(output.Bytes()) || strings.Contains(output.String(), "sensitive") || strings.Contains(output.String(), "example.invalid") {
			t.Fatal("invalid cloud request escaped desktop envelope")
		}
	}
}
