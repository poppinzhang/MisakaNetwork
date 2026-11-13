package control

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/aliyun"
	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/credentials"
	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/tencent"
	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/volcengine"
)

func TestAliyunActionsRejectMissingOrInvalidCredentials(t *testing.T) {
	for _, action := range []string{"aliyun_zones", "aliyun_prepare", "aliyun_create", "aliyun_describe", "aliyun_release", "aliyun_recover", "aliyun_network_lookup", "aliyun_network_create"} {
		for _, input := range []*aliyun.Input{nil, {SecretID: "invalid\ncredential", SecretKey: "sensitive-secret"}} {
			response := Handle(Request{Action: action, Aliyun: input})
			encoded, _ := json.Marshal(response)
			if response.OK || response.Error == "" || response.Result != nil || strings.Contains(string(encoded), "sensitive") || strings.Contains(string(encoded), "invalid") {
				t.Fatalf("%s returned unsafe failure", action)
			}
			if input != nil && response.Error != "阿里云 API 凭据格式无效" {
				t.Fatalf("%s did not route through Aliyun credential validation: %s", action, response.Error)
			}
		}
	}
}

func TestCloudEnvelopesRejectEveryMixedProviderPair(t *testing.T) {
	providers := []struct {
		action string
		apply  func(*Request)
	}{
		{"aliyun_describe", func(r *Request) { r.Aliyun = &aliyun.Input{SecretID: "fixture", SecretKey: "sensitive-secret"} }},
		{"tencent_describe", func(r *Request) { r.Cloud = &tencent.Input{SecretID: "fixture", SecretKey: "sensitive-secret"} }},
		{"volcengine_describe", func(r *Request) { r.Volcengine = &volcengine.Input{SecretID: "fixture", SecretKey: "sensitive-secret"} }},
		{"verify_cloud_credential", func(r *Request) {
			r.CloudCredential = &credentials.Input{Provider: "aliyun", AccessKeyID: "fixture", AccessKeySecret: "sensitive-secret"}
		}},
	}
	for i, first := range providers {
		for j, second := range providers {
			if i == j {
				continue
			}
			request := Request{Action: first.action}
			first.apply(&request)
			second.apply(&request)
			response := Handle(request)
			if response.OK || response.Error == "" || response.Result != nil || strings.Contains(response.Error, "sensitive") {
				t.Fatalf("mixed %s/%s escaped validation", first.action, second.action)
			}
		}
	}
}
