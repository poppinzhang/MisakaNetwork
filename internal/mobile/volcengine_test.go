package mobile

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
)

func TestVolcengineMobileEnvelopeRejectsInvalidCloudRequestWithoutFiles(t *testing.T) {
	root := t.TempDir()
	for _, request := range []string{
		`{"action":"volcengine_zones","volcengine":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"volcengine_zones","volcengine":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"volcengine_network_lookup","volcengine":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"volcengine_network_create","volcengine":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"volcengine_describe","volcengine":{"secret_id":"invalid\nheader","secret_key":"sensitive-secret"}}`,
		`{"action":"volcengine_create","volcengine":{"secret_id":"fixture","secret_key":"sensitive-secret","endpoint":"https://example.invalid"}}`,
		`{"action":"volcengine_prepare","volcengine":{"secret_id":"fixture","secret_key":"sensitive-secret","template":{"id":"fixture","runInstances":{"UserData":"sensitive-secret"}}}}`,
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
