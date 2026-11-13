package mobile

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
)

func TestAliyunMobileEnvelopeRejectsInvalidCloudRequestWithoutFiles(t *testing.T) {
	root := t.TempDir()
	for _, request := range []string{
		`{"action":"aliyun_zones","aliyun":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"aliyun_zones","aliyun":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"aliyun_network_lookup","aliyun":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"aliyun_network_create","aliyun":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"aliyun_describe","aliyun":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"aliyun_create","aliyun":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"aliyun_prepare","aliyun":{"secret_id":"fixture","secret_key":"sensitive-secret","template":{"id":"fixture","runInstances":{"UserData":"sensitive-secret"}}}}`,
	} {
		result := Handle([]byte(request), root)
		var response control.Response
		if json.Unmarshal(result, &response) != nil || response.OK || response.Error == "" || strings.Contains(string(result), "sensitive") || strings.Contains(string(result), "example.invalid") {
			t.Fatal("invalid cloud request escaped mobile envelope")
		}
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatal("cloud request wrote a file")
	}
}
