package control

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/tencent"
	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/volcengine"
)

func TestVolcengineActionsUseSafeCloudHelperErrors(t *testing.T) {
	for _, action := range []string{"volcengine_zones", "volcengine_prepare", "volcengine_create", "volcengine_describe", "volcengine_release", "volcengine_recover", "volcengine_network_lookup", "volcengine_network_create"} {
		for _, cloud := range []*volcengine.Input{nil, {SecretID: "invalid\ncredential", SecretKey: "sensitive-secret"}} {
			response := Handle(Request{Action: action, Volcengine: cloud})
			encoded, _ := json.Marshal(response)
			if response.OK || response.Error == "" || response.Result != nil || strings.Contains(string(encoded), "sensitive") || strings.Contains(string(encoded), "invalid") {
				t.Fatal("cloud helper returned unsafe failure")
			}
		}
	}
}

func TestCloudEnvelopesRejectMixedProvidersBeforeNetwork(t *testing.T) {
	for _, action := range []string{"tencent_describe", "volcengine_describe"} {
		response := Handle(Request{Action: action,
			Cloud:      &tencent.Input{SecretID: "fixture", SecretKey: "sensitive-secret"},
			Volcengine: &volcengine.Input{SecretID: "fixture", SecretKey: "sensitive-secret"},
		})
		if response.OK || response.Error == "" || strings.Contains(response.Error, "sensitive") {
			t.Fatal("mixed provider request was accepted")
		}
	}
}

func TestVolcengineZoneQueryRoutesToCredentialValidation(t *testing.T) {
	response := Handle(Request{Action: "volcengine_zones", Volcengine: &volcengine.Input{
		SecretID: "invalid\ncredential", SecretKey: "sensitive-secret",
	}})
	if response.OK || response.Error != "火山引擎 API 凭据格式无效" {
		t.Fatal("zone inventory did not use the Volcengine adapter")
	}
}
