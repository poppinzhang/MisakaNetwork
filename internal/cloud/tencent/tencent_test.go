package tencent

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

const fixtureToken = "51e14a42-4cd8-4e90-b1f3-1ce5f3652d90"

func fixtureTemplate() Template {
	var t Template
	json.Unmarshal([]byte(`{"id":"test-template","name":"测试模板","description":"离线测试配置","cpu":2,"memoryGb":4,"diskGb":40,"architecture":"x64","os":"Ubuntu 24.04 LTS","sshUsername":"ubuntu","regionLabel":"测试地域","region":"ap-guangzhou","runInstances":{"Placement":{"Zone":"ap-guangzhou-7"},"InstanceType":"S5.MEDIUM4","ImageId":"img-fixture","SystemDisk":{"DiskType":"CLOUD_SSD","DiskSize":40},"InternetAccessible":{"InternetChargeType":"TRAFFIC_POSTPAID_BY_HOUR","InternetMaxBandwidthOut":5,"PublicIpAssigned":true}}}`), &t)
	return t
}

func fixtureInput() Input {
	raw, _ := json.Marshal(fixtureTemplate())
	return Input{SecretID: "fixture-id", SecretKey: "fixture-secret", Template: raw, ClientToken: fixtureToken, SecurityGroupID: "sg-fixture", KeyID: "skey-fixture", InstanceName: "测试云服务器", Region: "ap-guangzhou", InstanceID: "ins-fixture", VpcID: "vpc-fixture", SubnetID: "subnet-fixture"}
}

type callRecord struct {
	service, action, region string
	body                    map[string]any
}
type fakeAPI struct {
	t       *testing.T
	calls   []callRecord
	respond func(callRecord) (any, error)
}

func (f *fakeAPI) call(_ context.Context, service, action, region string, in, out any) error {
	f.t.Helper()
	raw, err := json.Marshal(in)
	if err != nil {
		f.t.Fatal(err)
	}
	var payload map[string]any
	json.Unmarshal(raw, &payload)
	c := callRecord{service, action, region, payload}
	f.calls = append(f.calls, c)
	response, err := f.respond(c)
	if err != nil {
		return err
	}
	raw, err = json.Marshal(response)
	if err != nil {
		f.t.Fatal(err)
	}
	return json.Unmarshal(raw, out)
}

func imageResponse() map[string]any {
	return map[string]any{"TotalCount": 1, "ImageSet": []any{map[string]any{"ImageId": "img-fixture", "OsName": "Ubuntu Server 24.04 LTS 64bit", "ImageType": "PUBLIC_IMAGE", "Architecture": "x86_64", "ImageState": "NORMAL", "Platform": "Ubuntu", "ImageSize": 20}}}
}
func policyResponse() map[string]any {
	ingress, egress := expectedPolicies()
	return map[string]any{"SecurityGroupPolicySet": map[string]any{"Ingress": ingress, "Egress": egress, "Version": "1"}}
}
func instanceResponse(i *instance) map[string]any {
	var instances []instance
	if i != nil {
		instances = append(instances, *i)
	}
	return map[string]any{"InstanceSet": instances, "TotalCount": len(instances), "RequestId": "fixture-request"}
}
func ownedInstance() instance {
	return instance{InstanceID: "ins-fixture", InstanceState: "RUNNING", InstanceChargeType: "POSTPAID_BY_HOUR", PublicIPAddresses: []string{"203.0.113.10"}, Tags: []tag{{Key: managedTag, Value: managedValue}, {Key: operationTag, Value: fixtureToken}}}
}

func TestTemplateRejectsUnsafeAndInconsistentParameters(t *testing.T) {
	template := fixtureTemplate()
	if err := template.Validate(); err != nil {
		t.Fatal(err)
	}
	changes := map[string]func(*Template){
		"wrong-zone":        func(t *Template) { t.RunInstances.Placement.Zone = "ap-shanghai-1" },
		"hostname-region":   func(t *Template) { t.Region = "evil.example" },
		"disk-size":         func(t *Template) { t.RunInstances.SystemDisk.DiskSize = 80 },
		"disk-type":         func(t *Template) { t.RunInstances.SystemDisk.DiskType = "LOCAL_BASIC" },
		"bandwidth-billing": func(t *Template) { t.RunInstances.InternetAccessible.InternetChargeType = "BANDWIDTH_PREPAID" },
		"bandwidth-limit":   func(t *Template) { t.RunInstances.InternetAccessible.InternetMaxBandwidthOut = 101 },
		"public-ip":         func(t *Template) { t.RunInstances.InternetAccessible.PublicIpAssigned = false },
		"architecture":      func(t *Template) { t.Architecture = "i386" },
		"os":                func(t *Template) { t.OS = "" },
		"name-controls":     func(t *Template) { t.Name = "test\n" },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			copy := template
			change(&copy)
			if copy.Validate() == nil {
				t.Fatal("unsafe template accepted")
			}
		})
	}
	for _, field := range []string{"InstanceChargeType", "InstanceCount", "DataDisks", "UserData", "LoginSettings", "SecurityGroupIds", "ClientToken", "LaunchTemplate", "Endpoint", "VirtualPrivateCloud"} {
		t.Run(field, func(t *testing.T) {
			raw, _ := json.Marshal(template)
			var value map[string]any
			json.Unmarshal(raw, &value)
			value["runInstances"].(map[string]any)[field] = "forbidden"
			raw, _ = json.Marshal(value)
			if _, err := parseTemplate(raw); err == nil {
				t.Fatal("unknown field accepted")
			}
		})
	}
	raw, _ := json.Marshal(template)
	if _, err := parseTemplate(append(raw, []byte(" {}")...)); err == nil {
		t.Fatal("multiple JSON values accepted")
	}
	if _, err := parseTemplate(bytes.Replace(raw, []byte(`"DiskType":"CLOUD_SSD"`), []byte(`"DiskType":"CLOUD_SSD","DiskId":"disk-existing"`), 1)); err == nil {
		t.Fatal("nested unknown field accepted")
	}
}

func TestTemplatePreservesMixedCaseInstanceFamilies(t *testing.T) {
	for _, instanceType := range []string{"S5.MEDIUM4", "S5t.MEDIUM4", "S5ne.19XLARGE298", "S5se.LARGE16", "S9pro.MEDIUM4", "GN10Xp.10XLARGE160"} {
		t.Run(instanceType, func(t *testing.T) {
			template := fixtureTemplate()
			template.RunInstances.InstanceType = instanceType
			raw, err := json.Marshal(template)
			if err != nil {
				t.Fatal(err)
			}
			parsed, err := parseTemplate(raw)
			if err != nil {
				t.Fatal(err)
			}
			if parsed.RunInstances.InstanceType != instanceType {
				t.Fatalf("instance type changed: got %q, want %q", parsed.RunInstances.InstanceType, instanceType)
			}
		})
	}
}

func TestTemplateRejectsRemovedSourceFields(t *testing.T) {
	for field, values := range map[string][]string{
		"sshCidr":  {"0.0.0.0/0", "192.0.2.0/24"},
		"grpcCidr": {"0.0.0.0/0", "198.51.100.0/24"},
	} {
		for _, value := range values {
			t.Run(field+"="+value, func(t *testing.T) {
				raw, _ := json.Marshal(fixtureTemplate())
				var template map[string]any
				json.Unmarshal(raw, &template)
				template[field] = value
				raw, _ = json.Marshal(template)
				if _, err := parseTemplate(raw); err == nil {
					t.Fatal("removed configurable access field accepted")
				}
			})
		}
	}
}

func TestTemplateRejectsMalformedInstanceTypes(t *testing.T) {
	for _, instanceType := range []string{"", "s5t.MEDIUM4", "S5t.medium4", "S5t", "S5t..MEDIUM4", "S5t.MEDIUM4/extra", "S5t.MEDIUM4;command", "S5t.MEDIUM4\n", " S5t.MEDIUM4", "S5t.MEDIUM4 ", "S5-t.MEDIUM4", "S5_t.MEDIUM4", "S5t.ＭＥＤＩＵＭ4", "<script>.MEDIUM4"} {
		t.Run(instanceType, func(t *testing.T) {
			template := fixtureTemplate()
			template.RunInstances.InstanceType = instanceType
			raw, err := json.Marshal(template)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := parseTemplate(raw); err == nil {
				t.Fatalf("malformed instance type accepted: %q", instanceType)
			}
		})
	}
}

func TestTC3OfficialCanonicalVectorAndIndependentSignature(t *testing.T) {
	// Canonical hash from https://cloud.tencent.com/document/api/213/30654 .
	payload := []byte(`{"Limit": 1, "Filters": [{"Values": ["\u672a\u547d\u540d"], "Name": "instance-name"}]}`)
	if got := sha([]byte(canonicalRequest("cvm.tencentcloudapi.com", "DescribeInstances", payload))); got != "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84" {
		t.Fatalf("canonical hash = %s", got)
	}
	// Signature independently generated with Python hashlib/hmac and synthetic
	// credentials. UTC date must remain correct even when the caller uses JST.
	stamp := time.Unix(1551113065, 0).In(time.FixedZone("JST", 9*3600))
	want := "TC3-HMAC-SHA256 Credential=fixture-id/2019-02-25/cvm/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature=3be2466b1401c33126eb669021e9c1f5586a264be46467efa9aeffb5cb5a7449"
	if got := authorization("fixture-id", "fixture-secret", "cvm", "DescribeInstances", payload, stamp); got != want {
		t.Fatal("signature mismatch")
	}
}

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestTransportPinsHTTPSAndRedactsFailure(t *testing.T) {
	c := newClient("fixture-id", "fixture-secret")
	transport := c.http.Transport.(*http.Transport)
	if transport.TLSClientConfig.InsecureSkipVerify || transport.TLSClientConfig.MinVersion == 0 {
		t.Fatal("TLS verification disabled")
	}
	if c.http.CheckRedirect(&http.Request{}, nil) != http.ErrUseLastResponse {
		t.Fatal("redirect accepted")
	}
	c.now = func() time.Time { return time.Unix(1551113065, 0) }
	calls := 0
	c.http.Transport = roundTrip(func(req *http.Request) (*http.Response, error) {
		calls++
		if req.URL.String() != "https://cvm.tencentcloudapi.com/" || req.Method != "POST" || req.GetBody != nil {
			t.Fatal("unexpected endpoint/method/replay")
		}
		if req.Header.Get("X-TC-Action") != "DescribeInstances" || req.Header.Get("X-TC-Version") != "2017-03-12" || !strings.Contains(req.Header.Get("Authorization"), "TC3-HMAC-SHA256") {
			t.Fatal("missing signed API headers")
		}
		body, _ := io.ReadAll(req.Body)
		if bytes.Contains(body, []byte("fixture-secret")) {
			t.Fatal("credential entered API body")
		}
		return nil, errors.New("https://sensitive-url: fixture-secret private-key")
	})
	var out map[string]any
	err := c.call(context.Background(), "cvm", "DescribeInstances", "ap-guangzhou", map[string]any{}, &out)
	if err == nil || calls != 1 || strings.Contains(err.Error(), "sensitive") || strings.Contains(err.Error(), "fixture") {
		t.Fatal("transport error leaked or request retried")
	}
}

func TestTransportRejectsBadResponsesAndDoesNotLeakCloudMessages(t *testing.T) {
	for _, body := range []string{`{"Response":{"Error":{"Code":"AuthFailure.SignatureFailure","Message":"sensitive-token"},"RequestId":"valid-id"}}`, `{"Response":{"RequestId":"sensitive\nbody"}}`, `{"Response":null}`, `not-json`, strings.Repeat("x", (2<<20)+1)} {
		c := newClient("fixture-id", "fixture-secret")
		c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
		})
		var out map[string]any
		err := c.call(context.Background(), "cvm", "DescribeInstances", "ap-guangzhou", map[string]any{}, &out)
		if err == nil || strings.Contains(err.Error(), "sensitive") || strings.Contains(err.Error(), "fixture-secret") {
			t.Fatal("invalid response accepted or leaked")
		}
	}
	c := newClient("fixture-id", "fixture-secret")
	c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 307, Body: io.NopCloser(strings.NewReader("sensitive-body")), Header: make(http.Header)}, nil
	})
	if err := c.call(context.Background(), "vpc", "DescribeSecurityGroups", "ap-guangzhou", nil, new(any)); err == nil || strings.Contains(err.Error(), "sensitive") {
		t.Fatal("redirect status accepted or leaked")
	}
}

func TestPrepareCreatesOnceAndRepairsOnlyMissingRules(t *testing.T) {
	private, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	key, _ := ssh.NewPublicKey(&private.PublicKey)
	template := fixtureTemplate()
	var imported, groupCreated bool
	var ingress, egress []policy
	api := &fakeAPI{t: t}
	api.respond = func(c callRecord) (any, error) {
		switch c.action {
		case "DescribeImages":
			return imageResponse(), nil
		case "DescribeKeyPairs":
			if !imported {
				return map[string]any{"TotalCount": 0, "KeyPairSet": []any{}}, nil
			}
			return map[string]any{"TotalCount": 1, "KeyPairSet": []any{map[string]any{"KeyId": "skey-fixture", "KeyName": "misaka_" + sha(key.Marshal())[:18], "ProjectId": 0, "PublicKey": string(ssh.MarshalAuthorizedKey(key))}}}, nil
		case "ImportKeyPair":
			if imported {
				t.Fatal("duplicate key import")
			}
			imported = true
			if c.body["ProjectId"] != float64(0) || strings.Contains(c.body["PublicKey"].(string), "PRIVATE") {
				t.Fatal("invalid public key import")
			}
			return map[string]any{"KeyId": "skey-fixture"}, nil
		case "DescribeSecurityGroups":
			if !groupCreated {
				return map[string]any{"TotalCount": 0, "SecurityGroupSet": []any{}}, nil
			}
			return map[string]any{"TotalCount": 1, "SecurityGroupSet": []any{map[string]any{"SecurityGroupId": "sg-fixture", "SecurityGroupName": groupName(), "SecurityGroupDesc": groupDescription, "ProjectId": "0"}}}, nil
		case "CreateSecurityGroup":
			if groupCreated {
				t.Fatal("duplicate group create")
			}
			groupCreated = true
			if c.body["GroupName"] != groupName() {
				t.Fatal("unstable group name")
			}
			return map[string]any{"SecurityGroup": map[string]any{"SecurityGroupId": "sg-fixture"}}, nil
		case "DescribeSecurityGroupPolicies":
			return map[string]any{"SecurityGroupPolicySet": map[string]any{"Ingress": ingress, "Egress": egress, "Version": "1"}}, nil
		case "CreateSecurityGroupPolicies":
			set := c.body["SecurityGroupPolicySet"].(map[string]any)
			if len(set) != 1 {
				t.Fatal("both directions written in one request")
			}
			if value, ok := set["Ingress"]; ok {
				raw, _ := json.Marshal(value)
				json.Unmarshal(raw, &ingress)
			}
			if value, ok := set["Egress"]; ok {
				raw, _ := json.Marshal(value)
				json.Unmarshal(raw, &egress)
			}
			return map[string]any{"RequestId": "fixture-request"}, nil
		default:
			t.Fatalf("unexpected action %s", c.action)
			return nil, nil
		}
	}
	otherTemplate := template
	otherTemplate.ID = "other-template"
	otherTemplate.Name = "另一模板"
	otherTemplate.RunInstances.Placement.Zone = "ap-guangzhou-6"
	for _, current := range []Template{template, otherTemplate} {
		result, err := prepare(context.Background(), api, current, string(ssh.MarshalAuthorizedKey(key)))
		if err != nil || result.SecurityGroupID != "sg-fixture" || result.KeyID != "skey-fixture" {
			t.Fatalf("prepare: %+v %v", result, err)
		}
	}
	if len(ingress) != 2 || ingress[0].Port != "22" || ingress[1].Port != "20001" ||
		ingress[0].Protocol != "TCP" || ingress[1].Protocol != "TCP" ||
		ingress[0].CidrBlock != "0.0.0.0/0" || ingress[1].CidrBlock != "0.0.0.0/0" ||
		ingress[0].Action != "ACCEPT" || ingress[1].Action != "ACCEPT" ||
		len(egress) != 1 || egress[0].Port != "" {
		t.Fatal("unexpected firewall rules")
	}
	// Reuse with an interrupted empty egress repairs exactly that direction.
	egress = nil
	before := len(api.calls)
	if _, err := prepare(context.Background(), api, template, string(ssh.MarshalAuthorizedKey(key))); err != nil {
		t.Fatal(err)
	}
	writes := 0
	for _, c := range api.calls[before:] {
		if c.action == "CreateSecurityGroupPolicies" {
			writes++
		}
	}
	if writes != 1 {
		t.Fatal("did not repair exactly the missing direction")
	}
}

func TestSecurityRulesRejectDriftAndUseFixedSources(t *testing.T) {
	if got, want := groupName(), "MisakaNetwork-Sisters-20001-"+sha([]byte("0.0.0.0/0\n0.0.0.0/0"))[:12]; got != want {
		t.Fatalf("existing group with the same policy would not be reused: %s", got)
	}
	_, outbound := expectedPolicies()
	for _, port := range []string{"all", "ALL", ""} {
		actual := []policy{{Protocol: "all", Port: port, CidrBlock: "0.0.0.0/0", Action: "ACCEPT"}}
		missing, err := missingPolicies(actual, outbound)
		if err != nil || len(missing) != 0 {
			t.Fatalf("equivalent ALL rule rejected: %v", err)
		}
	}
	expected, _ := expectedPolicies()
	for _, altered := range [][]policy{{{Protocol: "TCP", Port: "20001", CidrBlock: "192.0.2.0/24", Action: "ACCEPT"}}, append(append([]policy{}, expected...), policy{Protocol: "ALL", CidrBlock: "0.0.0.0/0", Action: "ACCEPT"}), {{Protocol: "TCP", Port: "22", CidrBlock: "0.0.0.0/0", Action: "ACCEPT", AddressTemplate: map[string]any{"AddressId": "ipm-extra"}}}} {
		if _, err := missingPolicies(altered, expected); err == nil {
			t.Fatal("drift accepted")
		}
	}
}

func TestImagePreflightRejectsNonLinuxArchitectureStateSizeAndDataDisks(t *testing.T) {
	for _, change := range []map[string]any{{"OsName": "Windows Server 2025"}, {"Platform": "FreeBSD"}, {"Architecture": "arm"}, {"ImageState": "CREATING"}, {"ImageSize": 80}, {"ImageSize": 0}, {"ImageId": "img-other"}, {"SnapshotSet": []map[string]any{{"DiskUsage": "DATA_DISK"}}}} {
		api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
			out := imageResponse()
			image := out["ImageSet"].([]any)[0].(map[string]any)
			for key, value := range change {
				image[key] = value
			}
			return out, nil
		}}
		if err := preflightImage(context.Background(), api, fixtureTemplate()); err == nil {
			t.Fatal("bad image accepted")
		}
	}
	template := fixtureTemplate()
	template.Architecture = "arm64"
	api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
		out := imageResponse()
		out["ImageSet"].([]any)[0].(map[string]any)["Architecture"] = "arm"
		return out, nil
	}}
	if err := preflightImage(context.Background(), api, template); err != nil {
		t.Fatal(err)
	}
}

func TestCreateConstrainsBillingCountOwnershipAndNeverRetriesMutation(t *testing.T) {
	in := fixtureInput()
	api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
		switch c.action {
		case "DescribeImages":
			return imageResponse(), nil
		case "DescribeSecurityGroupPolicies":
			return policyResponse(), nil
		case "DescribeVpcs":
			return vpcResponse(ownedVpc()), nil
		case "DescribeSubnets":
			return subnetResponse(ownedSubnet(fixtureTemplate(), "subnet-fixture", "10.8.0.0/24")), nil
		case "RunInstances":
			if c.body["InstanceChargeType"] != "POSTPAID_BY_HOUR" || c.body["InstanceCount"] != float64(1) || c.body["ClientToken"] != fixtureToken {
				t.Fatal("unsafe billing/count/token")
			}
			for _, key := range []string{"DataDisks", "UserData", "InstanceChargePrepaid", "LaunchTemplate", "Password"} {
				if _, ok := c.body[key]; ok {
					t.Fatal("forbidden creation field")
				}
			}
			login := c.body["LoginSettings"].(map[string]any)
			keys, ok := login["KeyIds"].([]any)
			if len(login) != 1 || !ok || len(keys) != 1 || keys[0] != in.KeyID {
				t.Fatal("creation must bind exactly the managed SSH key without password or login overrides")
			}
			network := c.body["VirtualPrivateCloud"].(map[string]any)
			if network["VpcId"] != in.VpcID || network["SubnetId"] != in.SubnetID {
				t.Fatal("purchase did not use the verified runtime network")
			}
			tags := c.body["TagSpecification"].([]any)[0].(map[string]any)["Tags"].([]any)
			if len(tags) != 2 || tags[1].(map[string]any)["Value"] != fixtureToken {
				t.Fatal("missing operation ownership")
			}
			return map[string]any{"InstanceIdSet": []string{"ins-fixture"}, "RequestId": "fixture-request"}, nil
		default:
			t.Fatal("unexpected action")
			return nil, nil
		}
	}}
	result, err := execute(context.Background(), api, "tencent_create", in)
	if err != nil || result.(Created).InstanceID != "ins-fixture" {
		t.Fatalf("create failed: %v", err)
	}
	previous := api.respond
	api.respond = func(c callRecord) (any, error) {
		if c.action == "RunInstances" {
			return nil, errors.New("request outcome unknown")
		}
		return previous(c)
	}
	api.calls = nil
	if _, err := execute(context.Background(), api, "tencent_create", in); err == nil {
		t.Fatal("mutation timeout hidden")
	}
	count := 0
	for _, c := range api.calls {
		if c.action == "RunInstances" {
			count++
		}
	}
	if count != 1 {
		t.Fatal("creation mutation replayed")
	}
}

func TestDescribeAndRecoveryVerifyExactOwnership(t *testing.T) {
	i := ownedInstance()
	api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) { return instanceResponse(&i), nil }}
	for _, action := range []string{"tencent_describe", "tencent_recover"} {
		result, err := execute(context.Background(), api, action, fixtureInput())
		if err != nil || !result.(Status).Exists || result.(Status).PublicIP != "203.0.113.10" {
			t.Fatalf("query failed: %v", err)
		}
	}
	recoverPayload := api.calls[len(api.calls)-1].body
	if _, ok := recoverPayload["InstanceIds"]; ok || len(recoverPayload["Filters"].([]any)) != 2 {
		t.Fatal("recover query is not scoped by both tags")
	}
	for _, change := range []func(*instance){func(i *instance) { i.InstanceID = "ins-other" }, func(i *instance) { i.Tags = nil }, func(i *instance) { i.Tags[1].Value = "different-token" }} {
		i = ownedInstance()
		change(&i)
		if _, err := execute(context.Background(), api, "tencent_describe", fixtureInput()); err == nil {
			t.Fatal("foreign instance accepted")
		}
	}
	api.respond = func(c callRecord) (any, error) {
		return map[string]any{"TotalCount": 2, "InstanceSet": []instance{ownedInstance(), ownedInstance()}}, nil
	}
	if _, err := execute(context.Background(), api, "tencent_recover", fixtureInput()); err == nil {
		t.Fatal("ambiguous recovery accepted")
	}
	api.respond = func(c callRecord) (any, error) { return instanceResponse(nil), nil }
	result, err := execute(context.Background(), api, "tencent_recover", fixtureInput())
	if err != nil || result.(Status).Exists {
		t.Fatal("absent recovery not represented accurately")
	}
}

func TestReleaseRejectsForeignBillingDisksAndEIPAndOnlySubmitsTermination(t *testing.T) {
	for _, scenario := range []string{"success", "prepaid", "foreign", "data-disk", "eip", "query-failure", "absent", "terminating"} {
		t.Run(scenario, func(t *testing.T) {
			i := ownedInstance()
			if scenario == "prepaid" {
				i.InstanceChargeType = "PREPAID"
			}
			if scenario == "foreign" {
				i.Tags = nil
			}
			if scenario == "data-disk" {
				i.DataDisks = []json.RawMessage{json.RawMessage(`{"DiskId":"disk-fixture"}`)}
			}
			if scenario == "terminating" {
				i.InstanceState = "TERMINATING"
			}
			api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
				switch c.action {
				case "DescribeInstances":
					if scenario == "query-failure" {
						return nil, errors.New("query failed")
					}
					if scenario == "absent" {
						return instanceResponse(nil), nil
					}
					return instanceResponse(&i), nil
				case "DescribeAddresses":
					if scenario == "eip" {
						return map[string]any{"TotalCount": 1, "AddressSet": []any{map[string]any{"AddressId": "eip-fixture"}}}, nil
					}
					return map[string]any{"TotalCount": 0, "AddressSet": []any{}}, nil
				case "TerminateInstances":
					if c.body["ReleaseAddress"] != false || c.body["ReleasePrepaidDataDisks"] != false || len(c.body["InstanceIds"].([]any)) != 1 || c.body["InstanceIds"].([]any)[0] != "ins-fixture" {
						t.Fatal("wrong termination scope")
					}
					return map[string]any{"RequestId": "release-request"}, nil
				default:
					t.Fatal("unexpected deletion action")
					return nil, nil
				}
			}}
			_, err := execute(context.Background(), api, "tencent_release", fixtureInput())
			wantSuccess := scenario == "success" || scenario == "absent" || scenario == "terminating"
			if (err == nil) != wantSuccess {
				t.Fatalf("result mismatch: %v", err)
			}
			mutations := 0
			for _, c := range api.calls {
				if c.action == "TerminateInstances" {
					mutations++
				}
			}
			if scenario == "success" && mutations != 1 || scenario != "success" && mutations != 0 {
				t.Fatal("unexpected termination")
			}
		})
	}
}

func TestInvalidInputsNeverReachNetwork(t *testing.T) {
	for _, action := range []string{"tencent_prepare", "tencent_create", "tencent_describe", "tencent_recover", "tencent_release", "tencent_network_lookup", "tencent_network_create"} {
		api := &fakeAPI{t: t, respond: func(callRecord) (any, error) { t.Fatal("invalid input reached network"); return nil, nil }}
		if _, err := execute(context.Background(), api, action, Input{}); err == nil {
			t.Fatal("empty input accepted")
		}
	}
	if _, err := Execute("tencent_create", Input{SecretID: "injected\r\nheader", SecretKey: "sensitive-secret"}); err == nil || strings.Contains(err.Error(), "sensitive") {
		t.Fatal("invalid credentials accepted or leaked")
	}
}

func TestIncompleteResponsesNeverMeanAbsentOrSafeToRelease(t *testing.T) {
	api := &fakeAPI{t: t, respond: func(callRecord) (any, error) { return map[string]any{"RequestId": "fixture-request"}, nil }}
	for _, action := range []string{"tencent_describe", "tencent_recover", "tencent_release"} {
		if _, err := execute(context.Background(), api, action, fixtureInput()); err == nil {
			t.Fatalf("incomplete %s response accepted", action)
		}
	}
	if err := reconcilePolicies(context.Background(), api, fixtureTemplate(), "sg-fixture", true); err == nil {
		t.Fatal("missing policy set accepted")
	}
	if _, err := ensureGroup(context.Background(), api, fixtureTemplate()); err == nil {
		t.Fatal("missing security groups accepted")
	}
	i := ownedInstance()
	api.respond = func(c callRecord) (any, error) {
		if c.action == "DescribeInstances" {
			return instanceResponse(&i), nil
		}
		if c.action == "DescribeAddresses" {
			return map[string]any{"RequestId": "fixture-request"}, nil
		}
		t.Fatal("incomplete address result caused a mutation")
		return nil, nil
	}
	if _, err := execute(context.Background(), api, "tencent_release", fixtureInput()); err == nil {
		t.Fatal("missing addresses accepted")
	}
	if emptyTemplate(map[string]any{"AddressId": []any{"malformed"}}) {
		t.Fatal("malformed address template accepted")
	}
}
