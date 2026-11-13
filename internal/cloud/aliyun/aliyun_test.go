package aliyun

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/crypto/ssh"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

type fake func(context.Context, string, string, string, url.Values, any) error

func (f fake) call(c context.Context, s, a, r string, p url.Values, o any) error {
	return f(c, s, a, r, p, o)
}
func put(o any, v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	return json.Unmarshal(b, o)
}
func page(p url.Values, container, item string, rows any, count int) map[string]any {
	return map[string]any{"RequestId": "request-1", "TotalCount": count, "PageNumber": mustInt(p.Get("PageNumber")), "PageSize": 50, container: map[string]any{item: rows}}
}
func mustInt(s string) int {
	n := 0
	for _, r := range s {
		n = n*10 + int(r-'0')
	}
	return n
}
func fixture() Template {
	var t Template
	json.Unmarshal([]byte(`{"id":"small","name":"Small","description":"Fixture configuration","cpu":2,"memoryGb":4,"diskGb":40,"architecture":"x64","os":"Ubuntu 24.04 LTS","sshUsername":"root","regionLabel":"Example","region":"cn-hangzhou","runInstances":{"ZoneId":"cn-hangzhou-h","InstanceType":"ecs.g7.large","ImageId":"ubuntu_24_04_x64_20G_alibase_fixture.vhd","SystemDisk":{"Category":"cloud_essd","Size":40},"InternetChargeType":"PayByTraffic","InternetMaxBandwidthOut":5}}`), &t)
	return t
}
func raw(t Template) json.RawMessage { b, _ := json.Marshal(t); return b }
func TestTemplateClosedPolicy(t *testing.T) {
	for _, r := range []struct {
		region, zone string
		valid        bool
	}{{"cn-hangzhou", "cn-hangzhou-h", true}, {"ap-southeast-1", "ap-southeast-1a", true}, {"us-west-1", "us-west-1b", true}, {"ap-southeast-1", "ap-southeast-1-a", false}, {"cn-hangzhou", "cn-hangzhouh", false}, {"cn-hangzhou", "cn-beijing-a", false}} {
		f := fixture()
		f.Region = r.region
		f.RunInstances.ZoneID = r.zone
		if (f.Validate() == nil) != r.valid {
			t.Fatalf("zone %+v", r)
		}
	}
	for _, change := range []func(*Template){func(f *Template) { f.RunInstances.InternetChargeType = "PayByBandwidth" }, func(f *Template) { f.DiskGB = 10 }, func(f *Template) { f.RunInstances.SystemDisk.Size = 41 }, func(f *Template) { f.RunInstances.SystemDisk.Category = "cloud" }, func(f *Template) { f.RunInstances.InternetMaxBandwidthOut = 0 }, func(f *Template) { f.Architecture = "x86" }, func(f *Template) { f.OS = "" }, func(f *Template) { f.Region = "example.invalid/path" }} {
		f := fixture()
		change(&f)
		if _, e := parseTemplate(raw(f)); e == nil {
			t.Fatal("unsafe template accepted")
		}
	}
	for _, extra := range []string{`"UserData":"script"`, `"SecretKey":"secret"`, `"VpcId":"vpc-external"`, `"Endpoint":"https://evil.invalid"`} {
		b := strings.Replace(string(raw(fixture())), `"runInstances":{`, `"runInstances":{`+extra+`,`, 1)
		if _, e := parseTemplate([]byte(b)); e == nil {
			t.Fatal(extra)
		}
	}
	b := strings.Replace(string(raw(fixture())), `"cpu":2`, `"cpu":1,"cpu":2`, 1)
	if _, e := parseTemplate([]byte(b)); e == nil {
		t.Fatal("duplicate template")
	}
}

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestACS3OfficialVector(t *testing.T) {
	// Official native HTTP example, including the complete expected signature.
	r, _ := http.NewRequest("POST", "https://ecs.cn-shanghai.aliyuncs.com/?ImageId=win2019_1809_x64_dtc_zh-cn_40G_alibase_20230811.vhd&RegionId=cn-shanghai", nil)
	r.Header.Set("x-acs-action", "RunInstances")
	r.Header.Set("x-acs-content-sha256", sha(nil))
	r.Header.Set("x-acs-date", "2023-10-26T10:22:32Z")
	r.Header.Set("x-acs-signature-nonce", "3156853299f313e23d1673dc12e1703d")
	r.Header.Set("x-acs-version", "2014-05-26")
	sign(r, "YourAccessKeyId", "YourAccessKeySecret")
	if !strings.HasSuffix(r.Header.Get("Authorization"), "Signature=06563a9e1b43f5dfe96b81484da74bceab24a1d853912eee15083a6f0f3283c0") {
		t.Fatal(r.Header.Get("Authorization"))
	}
}
func TestClientEndpointEncodingAndNoReplay(t *testing.T) {
	c := newClient("fixture", "sensitive-secret")
	calls := 0
	c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Host != "vpc.cn-hangzhou.aliyuncs.com" || r.Method != "POST" || r.Body != nil || r.GetBody != nil || r.Header.Get("x-acs-version") != "2016-04-28" || !strings.Contains(r.URL.RawQuery, "A%20%2B%2F") {
			t.Fatalf("unexpected request %s", r.URL.Host)
		}
		return nil, errors.New("sensitive-secret transport details")
	})
	p := params("VpcName", "A +/")
	var out any
	e := c.call(context.Background(), "vpc", "CreateVpc", "cn-hangzhou", p, &out)
	if e == nil || strings.Contains(e.Error(), "sensitive-secret") || calls != 1 || p.Get("RegionId") != "" {
		t.Fatalf("unsafe result %v %d", e, calls)
	}
	for _, service := range []string{"other", "ecs.evil.invalid"} {
		if c.call(context.Background(), service, "CreateVpc", "cn-hangzhou", p, &out) == nil {
			t.Fatal("service escaped")
		}
	}
	if c.call(context.Background(), "vpc", "DeleteVpc", "cn-hangzhou", p, &out) == nil {
		t.Fatal("arbitrary action")
	}
	if c.call(context.Background(), "vpc", "CreateVpc", "cn-hangzhou", params("RegionId", "other"), &out) == nil {
		t.Fatal("region override")
	}
	tr := newClient("id", "key").http.Transport.(*http.Transport)
	if tr.TLSClientConfig.InsecureSkipVerify || tr.TLSClientConfig.MinVersion < 0x303 || !tr.DisableKeepAlives || !tr.Protocols.HTTP1() || tr.Protocols.HTTP2() {
		t.Fatal("TLS/replay policy")
	}
}
func TestPurchaseRejectionRequiresUnambiguous4xx(t *testing.T) {
	for _, tc := range []struct {
		status      int
		body        string
		unavailable bool
	}{
		{400, `{"RequestId":"r-1","Code":"OperationDenied.NoStock","Message":"sensitive-secret"}`, true},
		{200, `{"RequestId":"r-1","Code":"OperationDenied.NoStock"}`, false},
		{500, `{"RequestId":"r-1","Code":"OperationDenied.NoStock"}`, false},
		{400, `{"RequestId":"r-1","Code":"OperationDenied.NoStock","InstanceIdSets":{"InstanceIdSet":["i-created"]}}`, false},
		{400, `{"RequestId":"r-1","Code":"OperationDenied.NoStock","Code":"OperationDenied.NoStock"}`, false},
		{400, `{"Code":"OperationDenied.NoStock"}`, false},
		{400, `{"RequestId":"r-1","Code":"QuotaExceed.DiskCapacity"}`, false},
	} {
		c := newClient("fixture", "key")
		c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: tc.status, Body: io.NopCloser(strings.NewReader(tc.body)), Header: make(http.Header)}, nil
		})
		var out any
		e := c.call(context.Background(), "ecs", "RunInstances", "cn-hangzhou", nil, &out)
		if zoneUnavailable(e) != tc.unavailable || e != nil && strings.Contains(e.Error(), "sensitive-secret") {
			t.Fatalf("%s %v", tc.body, e)
		}
	}
}
func TestPaginationFailsClosed(t *testing.T) {
	for _, edit := range []func(map[string]any){func(o map[string]any) { delete(o, "TotalCount") }, func(o map[string]any) { o["TotalCount"] = 1 }, func(o map[string]any) { o["NextToken"] = "unexpected" }, func(o map[string]any) { o["PageNumber"] = 2 }, func(o map[string]any) { o["Instances"] = map[string]any{"Instance": nil} }} {
		api := fake(func(_ context.Context, _, _, _ string, p url.Values, o any) error {
			v := page(p, "Instances", "Instance", []instance{}, 0)
			edit(v)
			return put(o, v)
		})
		_, _, e := pages[instance](context.Background(), api, "ecs", "cn-hangzhou", "DescribeInstances", "Instances", "Instance", nil)
		if e == nil {
			t.Fatal("ambiguous absence")
		}
	}
	calls := 0
	api := fake(func(_ context.Context, _, _, _ string, p url.Values, o any) error {
		calls++
		rows := []map[string]any{}
		start := 0
		if calls > 1 {
			start = 50
		}
		for i := start; i < min(start+50, 51); i++ {
			rows = append(rows, map[string]any{"n": i})
		}
		return put(o, page(p, "Rows", "Row", rows, 51))
	})
	rows, _, e := pages[map[string]any](context.Background(), api, "ecs", "cn-hangzhou", "DescribeInstances", "Rows", "Row", nil)
	if e != nil || len(rows) != 51 || calls != 2 {
		t.Fatalf("pagination %d %v", calls, e)
	}
}
func fixtureKey(t *testing.T) ssh.PublicKey {
	t.Helper()
	r, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	k, e := ssh.NewPublicKey(&r.PublicKey)
	if e != nil {
		t.Fatal(e)
	}
	return k
}
func fixtureRules() []permission {
	r := requiredRules()
	for i := range r {
		r[i].Policy = "Accept"
		r[i].NicType = "intranet"
		r[i].Priority = "1"
	}
	return r
}
func fixtureVpc() map[string]any {
	return map[string]any{"VpcId": "vpc-fixture", "VpcName": networkVpcName, "RegionId": "cn-hangzhou", "Status": "Available", "CidrBlock": networkVpcCIDR, "IsDefault": false, "Tags": map[string]any{"Tag": networkTags()}}
}
func fixtureSubnet() map[string]any {
	return map[string]any{"VSwitchId": "vsw-fixture", "VpcId": "vpc-fixture", "VSwitchName": subnetName(fixture().RunInstances.ZoneID), "ZoneId": fixture().RunInstances.ZoneID, "Status": "Available", "CidrBlock": "10.8.0.0/24", "AvailableIpAddressCount": 250, "Tags": map[string]any{"Tag": networkTags()}}
}
func fixtureInstance() map[string]any {
	return map[string]any{"InstanceId": "i-fixture", "Status": "Running", "InstanceChargeType": "PostPaid", "SpotStrategy": "NoSpot", "InstanceNetworkType": "vpc", "PublicIpAddress": map[string]any{"IpAddress": []string{"203.0.113.1"}}, "Tags": map[string]any{"Tag": []map[string]string{{"TagKey": managedTag, "TagValue": managedValue}, {"TagKey": operationTag, "TagValue": "operation-token-123"}}}}
}
func fixtureAPI(t *testing.T, key ssh.PublicKey, mutate func(string, url.Values, map[string]any) error) fake {
	return fake(func(_ context.Context, service, action, region string, p url.Values, o any) error {
		t.Helper()
		v := map[string]any{"RequestId": "request-1"}
		switch action {
		case "DescribeImages":
			v = page(p, "Images", "Image", []map[string]any{{"ImageId": fixture().RunInstances.ImageID, "ImageOwnerAlias": "system", "OSName": "Ubuntu 24.04 64 bit", "OSType": "linux", "Platform": "Ubuntu", "Status": "Available", "Architecture": "x86_64", "Size": 20, "DiskDeviceMappings": map[string]any{"DiskDeviceMapping": []map[string]any{{"Type": "system", "Size": "20"}}}}}, 1)
		case "DescribeVpcs":
			v = page(p, "Vpcs", "Vpc", []any{fixtureVpc()}, 1)
		case "DescribeVSwitches":
			v = page(p, "VSwitches", "VSwitch", []any{fixtureSubnet()}, 1)
		case "DescribeKeyPairs":
			v = page(p, "KeyPairs", "KeyPair", []map[string]any{{"KeyPairName": keyName(key), "PublicKey": string(ssh.MarshalAuthorizedKey(key))}}, 1)
		case "DescribeSecurityGroupAttribute":
			v = map[string]any{"RequestId": "request-1", "SecurityGroupId": "sg-fixture", "VpcId": "vpc-fixture", "SecurityGroupName": groupName, "Description": groupDescription, "InnerAccessPolicy": "Accept", "Permissions": map[string]any{"Permission": fixtureRules()}}
		case "DescribeSecurityGroups":
			v = page(p, "SecurityGroups", "SecurityGroup", []map[string]any{{"SecurityGroupId": "sg-fixture", "VpcId": "vpc-fixture", "SecurityGroupName": groupName, "Description": groupDescription, "SecurityGroupType": "normal", "Tags": map[string]any{"Tag": []map[string]string{{"TagKey": managedTag, "TagValue": managedValue}}}}}, 1)
		case "RunInstances":
			v["InstanceIdSets"] = map[string]any{"InstanceIdSet": []string{"i-fixture"}}
		case "DescribeInstances":
			v = page(p, "Instances", "Instance", []any{fixtureInstance()}, 1)
		case "DescribeDisks":
			v = page(p, "Disks", "Disk", []map[string]any{{"DiskId": "d-fixture", "InstanceId": "i-fixture", "Type": "system", "Status": "In_use", "DeleteWithInstance": true}}, 1)
		case "DeleteInstance":
		default:
			t.Fatalf("unexpected action %s", action)
		}
		if mutate != nil {
			if e := mutate(action, p, v); e != nil {
				return e
			}
		}
		return put(o, v)
	})
}
func createInput(key ssh.PublicKey) Input {
	return Input{SecretID: "fixture", Template: raw(fixture()), PublicKey: string(ssh.MarshalAuthorizedKey(key)), ClientToken: "operation-token-123", SecurityGroupID: "sg-fixture", KeyID: keyName(key), VpcID: "vpc-fixture", SubnetID: "vsw-fixture", InstanceName: "Fixture instance", InstanceID: "i-fixture", Region: "cn-hangzhou"}
}
func TestPrepareAndCreateFixedPolicy(t *testing.T) {
	k := fixtureKey(t)
	in := createInput(k)
	purchased := 0
	api := fixtureAPI(t, k, func(action string, p url.Values, _ map[string]any) error {
		if action == "RunInstances" {
			purchased++
			for key, value := range map[string]string{"Amount": "1", "MinAmount": "1", "InstanceChargeType": "PostPaid", "SpotStrategy": "NoSpot", "KeyPairName": in.KeyID, "VSwitchId": in.SubnetID, "InternetChargeType": "PayByTraffic", "ImageOptions.LoginAsNonRoot": "false", "PasswordInherit": "false", "Tag.2.Value": in.ClientToken, "SystemDisk.PerformanceLevel": "PL1"} {
				if p.Get(key) != value {
					t.Fatalf("%s %s", key, p.Get(key))
				}
			}
			for _, key := range []string{"UserName", "Password", "UserData", "SystemDisk.DeleteWithInstance", "DataDisk.1.Size", "EipAddress"} {
				if p.Has(key) {
					t.Fatal(key)
				}
			}
		}
		return nil
	})
	prepared, e := prepare(context.Background(), api, fixture(), in)
	if e != nil || prepared.KeyID != in.KeyID || prepared.SecurityGroupID != in.SecurityGroupID {
		t.Fatalf("prepare %+v %v", prepared, e)
	}
	got, e := create(context.Background(), api, fixture(), in)
	if e != nil || got.InstanceID != "i-fixture" || purchased != 1 {
		t.Fatalf("create %+v %v", got, e)
	}
}
func TestCreateRefusesChangedImageNetworkRulesOrKey(t *testing.T) {
	for _, bad := range []string{"image", "network", "rules", "key"} {
		t.Run(bad, func(t *testing.T) {
			k := fixtureKey(t)
			writes := 0
			api := fixtureAPI(t, k, func(a string, p url.Values, v map[string]any) error {
				if a == "RunInstances" {
					writes++
				}
				switch {
				case bad == "image" && a == "DescribeImages":
					v["Images"] = map[string]any{"Image": []any{}}
				case bad == "network" && a == "DescribeVpcs":
					v["Vpcs"] = map[string]any{"Vpc": []map[string]any{{"VpcId": "vpc-fixture", "VpcName": networkVpcName}}}
				case bad == "rules" && a == "DescribeSecurityGroupAttribute":
					v["VpcId"] = "vpc-external"
				case bad == "key" && a == "DescribeKeyPairs":
					v["KeyPairs"] = map[string]any{"KeyPair": []map[string]any{{"KeyPairName": keyName(k), "PublicKey": "invalid"}}}
				}
				return nil
			})
			if _, e := create(context.Background(), api, fixture(), createInput(k)); e == nil || writes != 0 {
				t.Fatalf("unsafe create %v %d", e, writes)
			}
		})
	}
}
func TestReleaseChecksOwnershipDisksAndEIP(t *testing.T) {
	for _, bad := range []string{"", "eip", "disk-retained", "extra-disk", "wrong-token", "prepaid", "transition", "extra-eni"} {
		t.Run(bad, func(t *testing.T) {
			k := fixtureKey(t)
			writes := 0
			api := fixtureAPI(t, k, func(a string, p url.Values, v map[string]any) error {
				if a == "DeleteInstance" {
					writes++
					if p.Get("InstanceId") != "i-fixture" || p.Get("Force") != "true" || p.Get("ForceStop") != "false" {
						t.Fatal(p)
					}
				}
				if a == "DescribeInstances" {
					row := fixtureInstance()
					switch bad {
					case "extra-eni":
						row["NetworkInterfaces"] = map[string]any{"NetworkInterface": []map[string]any{{"NetworkInterfaceId": "eni-extra", "Type": "Secondary"}}}
					case "eip":
						row["EipAddress"] = map[string]any{"AllocationId": "eip-external"}
					case "wrong-token":
						row["Tags"] = nil
					case "prepaid":
						row["InstanceChargeType"] = "PrePaid"
					case "transition":
						row["Status"] = "Starting"
					}
					v["Instances"] = map[string]any{"Instance": []any{row}}
				}
				if a == "DescribeDisks" && (bad == "disk-retained" || bad == "extra-disk") {
					row := map[string]any{"DiskId": "d-fixture", "InstanceId": "i-fixture", "Type": "system", "DeleteWithInstance": false}
					if bad == "extra-disk" {
						row["Type"] = "data"
					}
					v["Disks"] = map[string]any{"Disk": []any{row}}
				}
				return nil
			})
			_, e := release(context.Background(), api, createInput(k))
			if (e == nil) != (bad == "") || writes != map[bool]int{true: 1, false: 0}[bad == ""] {
				t.Fatalf("release %v writes=%d", e, writes)
			}
		})
	}
}
func TestRecoverUsesTagsAndUnknownNeverPurchases(t *testing.T) {
	k := fixtureKey(t)
	api := fixtureAPI(t, k, func(a string, p url.Values, v map[string]any) error {
		if a != "DescribeInstances" {
			t.Fatalf("mutation during recovery %s", a)
		}
		if p.Get("Tag.1.Key") != managedTag || p.Get("Tag.2.Value") != "operation-token-123" || p.Has("ClientToken") || p.Has("InstanceIds") {
			t.Fatal(p)
		}
		return nil
	})
	s, e := describe(context.Background(), api, createInput(k), true)
	if e != nil || !s.Exists || s.State != "RUNNING" {
		t.Fatalf("%+v %v", s, e)
	}
}
func TestWaitCancelledDoesNotCall(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	called := false
	if e := waitPreparation(ctx, func(context.Context) (bool, error) { called = true; return false, nil }); e == nil || called {
		t.Fatal(e)
	}
}
func TestUniqueJSON(t *testing.T) {
	for _, s := range []string{`{"a":1,"a":2}`, `{"Code":"x","code":""}`, `{"InstanceIdSets":{},"instanceidsets":null}`, `{"a":{"b":1,"b":2}}`, `{"a":1} {}`, `{"a":[1,2]`} {
		if uniqueJSON([]byte(s)) {
			t.Fatal(s)
		}
	}
	if !uniqueJSON([]byte(`{"a":[1,{"b":2}],"c":null}`)) {
		t.Fatal("valid JSON")
	}
}

func TestTokenPaginationExhaustsAndRejectsBrokenContinuation(t *testing.T) {
	calls := 0
	api := fake(func(_ context.Context, _, _, _ string, p url.Values, o any) error {
		calls++
		if p.Has("PageNumber") || p.Has("PageSize") || p.Get("MaxResults") != "50" {
			t.Fatal(p)
		}
		if calls == 1 {
			return put(o, map[string]any{"RequestId": "request-1", "NextToken": "next-page", "Rows": map[string]any{"Row": []map[string]any{{"id": "first"}}}})
		}
		if p.Get("NextToken") != "next-page" {
			t.Fatal(p)
		}
		return put(o, map[string]any{"RequestId": "request-2", "Rows": map[string]any{"Row": []map[string]any{{"id": "second"}}}})
	})
	rows, rid, e := tokenPages[map[string]any](context.Background(), api, "ecs", "cn-hangzhou", "DescribeInstances", "Rows", "Row", nil)
	if e != nil || len(rows) != 2 || rid != "request-2" || calls != 2 {
		t.Fatalf("%v %s %d %v", rows, rid, calls, e)
	}
	for _, mode := range []string{"empty-next", "repeat-next", "repeat-row", "missing-rows"} {
		t.Run(mode, func(t *testing.T) {
			calls := 0
			api := fake(func(_ context.Context, _, _, _ string, p url.Values, o any) error {
				calls++
				v := map[string]any{"NextToken": "next", "Rows": map[string]any{"Row": []map[string]any{{"id": fmt.Sprintf("row-%d", calls)}}}}
				switch mode {
				case "empty-next":
					v["Rows"] = map[string]any{"Row": []any{}}
				case "repeat-row":
					v["Rows"] = map[string]any{"Row": []map[string]any{{"id": "same"}}}
				case "missing-rows":
					delete(v, "Rows")
				}
				return put(o, v)
			})
			if _, _, e := tokenPages[map[string]any](context.Background(), api, "ecs", "cn-hangzhou", "DescribeInstances", "Rows", "Row", nil); e == nil || calls > 2 {
				t.Fatalf("%s %d %v", mode, calls, e)
			}
		})
	}
}

func TestTokenPaginationRefusesNullRows(t *testing.T) {
	for _, v := range []map[string]any{
		{"Rows": map[string]any{"Row": []any{nil}}},
		{"Rows": map[string]any{"Row": nil}},
	} {
		api := fake(func(_ context.Context, _, _, _ string, _ url.Values, o any) error { return put(o, v) })
		if _, _, e := tokenPages[map[string]any](context.Background(), api, "ecs", "cn-hangzhou", "DescribeInstances", "Rows", "Row", nil); e == nil {
			t.Fatalf("invalid pagination accepted %+v", v)
		}
	}
}
