package control

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/tencent"
)

func TestTencentActionsUseSafeCloudHelperErrors(t *testing.T) {
	for _, action := range []string{"tencent_prepare", "tencent_create", "tencent_describe", "tencent_release", "tencent_recover"} {
		for _, cloud := range []*tencent.Input{nil, {SecretID: "invalid\ncredential", SecretKey: "sensitive-secret"}} {
			response := Handle(Request{Action: action, Cloud: cloud})
			encoded, _ := json.Marshal(response)
			if response.OK || response.Error == "" || response.Result != nil || strings.Contains(string(encoded), "sensitive") || strings.Contains(string(encoded), "invalid") {
				t.Fatal("cloud helper returned unsafe failure")
			}
		}
	}
}
