package mobile

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
)

func TestCredentialMobileEnvelopeRejectsUnsafeRequestsWithoutWritingFiles(t *testing.T) {
	root := t.TempDir()
	for _, request := range []string{
		`{"action":"verify_cloud_credential"}`,
		`{"action":"verify_cloud_credential","cloud_credential":{"provider":"tencent","access_key_id":"fixture-id","access_key_secret":"fixture-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"verify_cloud_credential","cloud_credential":{"provider":"aliyun","access_key_id":"fixture-id","access_key_secret":"fixture-secret","action":"RunInstances"}}`,
		`{"action":"verify_cloud_credential","cloud_credential":{"provider":"volcengine","access_key_id":"bad\nheader","access_key_secret":"fixture-secret"}}`,
	} {
		result := Handle([]byte(request), root)
		var response control.Response
		if json.Unmarshal(result, &response) != nil || response.OK || response.Error == "" || strings.Contains(string(result), "fixture") || strings.Contains(string(result), "example.invalid") {
			t.Fatal("invalid credential request escaped mobile envelope")
		}
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatal("credential verification wrote a file")
	}
}
