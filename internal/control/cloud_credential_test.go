package control

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/credentials"
)

func TestCloudCredentialVerificationRequiresSafeInput(t *testing.T) {
	for _, input := range []*credentials.Input{nil, {Provider: "tencent", AccessKeyID: "bad\nheader", AccessKeySecret: "fixture-secret"}, {Provider: "https://example.invalid", AccessKeyID: "fixture-id", AccessKeySecret: "fixture-secret"}} {
		response := Handle(Request{Action: "verify_cloud_credential", CloudCredential: input})
		raw, _ := json.Marshal(response)
		if response.OK || response.Result != nil || response.Error == "" || strings.Contains(string(raw), "fixture") || strings.Contains(string(raw), "example.invalid") {
			t.Fatal("invalid credential verification escaped control envelope")
		}
	}
}
