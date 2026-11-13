package volcengine

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

const fixtureTemplate = `{"id":"fixture","name":"测试规格","description":"离线测试","cpu":2,"memoryGb":4,"diskGb":40,"architecture":"x64","os":"Ubuntu 24.04 LTS","sshUsername":"root","regionLabel":"测试地域","region":"cn-beijing","runInstances":{"ZoneId":"cn-beijing-a","InstanceTypeId":"ecs.g3i.large","ImageId":"image-fixture","Volumes":[{"VolumeType":"ESSD_PL0","Size":40}],"EipAddress":{"BandwidthMbps":5,"ISP":"BGP","ChargeType":"PayByTraffic","ReleaseWithInstance":true}}}`
const fixtureToken = "fixture-operation-12345678"

func fixture(t *testing.T) Template {
	t.Helper()
	v, e := parseTemplate([]byte(fixtureTemplate))
	if e != nil {
		t.Fatal(e)
	}
	return v
}
func input() Input {
	return Input{Region: "cn-beijing", InstanceID: "i-fixture", EipID: "eip-fixture", ClientToken: fixtureToken, Template: []byte(fixtureTemplate), VpcID: "vpc-fixture", SubnetID: "subnet-fixture", SubnetCIDR: "10.8.0.0/24", SecurityGroupID: "sg-fixture", KeyID: "misaka-0123456789abcdef0123456789abcdef", InstanceName: "fixture"}
}

type fakeAPI struct {
	t     *testing.T
	calls []string
	f     func(string, url.Values) (any, error)
}

func (a *fakeAPI) call(ctx context.Context, service, action, region string, q url.Values, out any) error {
	a.t.Helper()
	a.calls = append(a.calls, action)
	if !allowedActions[service][action] || region != "cn-beijing" {
		a.t.Fatalf("unexpected API %s/%s/%s", service, action, region)
	}
	v, e := a.f(action, q)
	if e != nil {
		return e
	}
	b, e := json.Marshal(v)
	if e != nil {
		a.t.Fatal(e)
	}
	return json.Unmarshal(b, out)
}
func ownership() []tag { return []tag{{managedTag, managedValue}, {operationTag, fixtureToken}} }
func running() instance {
	i := instance{InstanceID: "i-fixture", Status: "RUNNING", InstanceChargeType: "PostPaid", Tags: ownership()}
	i.EipAddress.AllocationID = "eip-fixture"
	i.EipAddress.IpAddress = "203.0.113.7"
	i.Volumes = append(i.Volumes, struct {
		VolumeID string `json:"VolumeId"`
	}{"vol-fixture"})
	return i
}
func boolp(v bool) *bool { return &v }
func intp(v int) *int    { return &v }
func address() eip {
	return eip{AllocationID: "eip-fixture", InstanceID: "i-fixture", InstanceType: "EcsInstance", Status: "Attached", EipAddress: "203.0.113.7", BillingType: 3, ReleaseWithInstance: boolp(true)}
}
func validVpc() networkVpc {
	return networkVpc{VpcID: "vpc-fixture", VpcName: networkVpcName, CidrBlock: networkVpcCIDR, Status: "Available", Tags: networkTags()}
}
func validSubnet() networkSubnet {
	return networkSubnet{SubnetID: "subnet-fixture", VpcID: "vpc-fixture", SubnetName: subnetName("cn-beijing-a"), ZoneID: "cn-beijing-a", CidrBlock: "10.8.0.0/24", Status: "Available", Tags: networkTags(), AvailableIpAddressCount: intp(200)}
}
func validGroup() group {
	p := requiredPolicies()
	return group{SecurityGroupID: "sg-fixture", SecurityGroupName: groupName, Description: groupDescription, VpcID: "vpc-fixture", Status: "Available", Type: "normal", Tags: []tag{{managedTag, managedValue}}, Permissions: &p}
}
func purchaseRead(action string) (any, error) {
	switch action {
	case "DescribeImages":
		return map[string]any{"Images": []any{map[string]any{"ImageId": "image-fixture", "Visibility": "public", "OsType": "Linux", "Status": "available", "Platform": "Ubuntu", "OsName": "Ubuntu 24.04 LTS", "Architecture": "amd64", "Size": 20}}}, nil
	case "DescribeVpcs":
		return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
	case "DescribeSubnets":
		return map[string]any{"Subnets": []networkSubnet{validSubnet()}}, nil
	case "DescribeSecurityGroupAttributes":
		return validGroup(), nil
	}
	return nil, errors.New("unexpected action")
}

func TestTemplateRejectsLifecycleOverrideAndUnknownFields(t *testing.T) {
	fixture(t)
	for _, pair := range [][2]string{{`"ReleaseWithInstance":true`, `"ReleaseWithInstance":false`}, {`"ChargeType":"PayByTraffic"`, `"ChargeType":"PrePaid"`}, {`"Size":40`, `"Size":41`}, {`"ZoneId":"cn-beijing-a"`, `"ZoneId":"cn-shanghai-a"`}, {`"VolumeType":"ESSD_PL0"`, `"VolumeType":"PTSSD"`}, {`"ImageId":"image-fixture"`, `"ImageId":"image-fixture","UserData":"injection"`}, {`"region":"cn-beijing"`, `"region":"evil.example"`}, {`"Volumes":[`, `"Volumes":[{"VolumeType":"ESSD_PL0","Size":40},`}} {
		if _, e := parseTemplate([]byte(strings.Replace(fixtureTemplate, pair[0], pair[1], 1))); e == nil {
			t.Errorf("accepted %v", pair)
		}
	}
}
func TestCreatePinsChargeCountDiskAndEipLifetime(t *testing.T) {
	a := &fakeAPI{t: t}
	a.f = func(action string, q url.Values) (any, error) {
		if action != "RunInstances" {
			return purchaseRead(action)
		}
		for k, w := range map[string]string{"InstanceChargeType": "PostPaid", "Count": "1", "MinCount": "1", "SpotStrategy": "NoSpot", "EipAddress.ReleaseWithInstance": "true", "EipAddress.ChargeType": "PayByTraffic", "Volumes.1.DeleteWithInstance": "true", "NetworkInterfaces.1.SubnetId": "subnet-fixture", "NetworkInterfaces.1.SecurityGroupIds.1": "sg-fixture", "ClientToken": fixtureToken, "Tags.2.Value": fixtureToken, "KeyPairName": input().KeyID} {
			if q.Get(k) != w {
				t.Errorf("%s=%s, want %s", k, q.Get(k), w)
			}
		}
		for _, k := range []string{"Password", "UserData", "EipAddress.AllocationId", "Volumes.2.Size", "SecurityToken"} {
			if q.Has(k) {
				t.Errorf("unexpected %s", k)
			}
		}
		return map[string]any{"InstanceIds": []string{"i-fixture"}, "RequestId": "request-1"}, nil
	}
	r, e := create(context.Background(), a, fixture(t), input())
	if e != nil || r.InstanceID != "i-fixture" {
		t.Fatalf("%+v %v", r, e)
	}
}
func TestCreateDoesNotRetryAmbiguousPurchase(t *testing.T) {
	a := &fakeAPI{t: t}
	a.f = func(action string, q url.Values) (any, error) {
		if action == "RunInstances" {
			return nil, errors.New("network failed")
		}
		return purchaseRead(action)
	}
	_, e := create(context.Background(), a, fixture(t), input())
	if e == nil {
		t.Fatal("accepted")
	}
	n := 0
	for _, c := range a.calls {
		if c == "RunInstances" {
			n++
		}
	}
	if n != 1 {
		t.Fatal(a.calls)
	}
}
func TestImageRejectsNonLinuxArchitectureStateSizeAndDataDisks(t *testing.T) {
	for _, change := range []map[string]any{{"OsType": "Windows"}, {"OsType": ""}, {"Architecture": "arm64"}, {"Size": 41}, {"Size": 0}, {"Status": "creating"}, {"ImageId": "image-other"}, {"Snapshots": []map[string]any{{"VolumeKind": "data"}}}} {
		a := &fakeAPI{t: t, f: func(string, url.Values) (any, error) {
			v, _ := purchaseRead("DescribeImages")
			m := v.(map[string]any)["Images"].([]any)[0].(map[string]any)
			for k, v := range change {
				m[k] = v
			}
			return v, nil
		}}
		if e := preflightImage(context.Background(), a, fixture(t)); e == nil {
			t.Errorf("accepted %v", change)
		}
	}
}
func TestDescribePersistsOnlyMatchingReleaseableEip(t *testing.T) {
	a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
		if action == "DescribeInstances" {
			return map[string]any{"Instances": []instance{running()}}, nil
		}
		return map[string]any{"EipAddresses": []eip{address()}}, nil
	}}
	in := input()
	in.EipID = ""
	r, e := describe(context.Background(), a, in, false)
	if e != nil || r.EipID != "eip-fixture" || r.PublicIP != "203.0.113.7" || r.State != "RUNNING" {
		t.Fatalf("%+v %v", r, e)
	}
	in.EipID = "eip-other"
	if _, e = describe(context.Background(), a, in, false); e == nil {
		t.Fatal("accepted replaced EIP")
	}
}
func TestReleaseChecksOwnedEipAndPerInstanceResult(t *testing.T) {
	a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
		switch action {
		case "DescribeInstances":
			return map[string]any{"Instances": []instance{running()}}, nil
		case "DescribeEipAddresses":
			if q.Get("AllocationIds.1") != "eip-fixture" {
				t.Fatal(q)
			}
			return map[string]any{"EipAddresses": []eip{address()}}, nil
		case "DeleteInstances":
			if q.Get("InstanceIds.1") != "i-fixture" || !tokenPattern.MatchString(q.Get("ClientToken")) {
				t.Fatal(q)
			}
			return map[string]any{"OperationDetails": []any{map[string]any{"InstanceId": "i-fixture"}}, "RequestId": "request-1"}, nil
		}
		t.Fatal(action)
		return nil, nil
	}}
	r, e := release(context.Background(), a, input())
	if e != nil || r.EipID != "eip-fixture" {
		t.Fatalf("%+v %v", r, e)
	}
}
func TestReleaseRefusesUntrackedOrChangedEipAndExtraDisk(t *testing.T) {
	for _, mode := range []string{"no-local-id", "changed-id", "release-false", "wrong-binding", "prepaid-eip", "extra-disk", "prepaid-instance", "missing-eip"} {
		t.Run(mode, func(t *testing.T) {
			in := input()
			i := running()
			ip := address()
			if mode == "no-local-id" {
				in.EipID = ""
			}
			switch mode {
			case "changed-id":
				i.EipAddress.AllocationID = "eip-other"
			case "release-false":
				ip.ReleaseWithInstance = boolp(false)
			case "wrong-binding":
				ip.InstanceID = "i-other"
			case "prepaid-eip":
				ip.BillingType = 1
			case "extra-disk":
				i.Volumes = append(i.Volumes, i.Volumes[0])
			case "prepaid-instance":
				i.InstanceChargeType = "PrePaid"
			}
			a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
				switch action {
				case "DescribeInstances":
					return map[string]any{"Instances": []instance{i}}, nil
				case "DescribeEipAddresses":
					ips := []eip{ip}
					if mode == "missing-eip" {
						ips = []eip{}
					}
					return map[string]any{"EipAddresses": ips}, nil
				default:
					t.Fatal("unexpected mutation", action)
					return nil, nil
				}
			}}
			if _, e := release(context.Background(), a, in); e == nil {
				t.Fatal("accepted")
			}
		})
	}
}
func TestReleaseFailureDoesNotBecomeSuccessFromHTTP200(t *testing.T) {
	for _, details := range []any{nil, []any{}, []any{map[string]any{"InstanceId": "i-other"}}, []any{map[string]any{"InstanceId": "i-fixture", "Error": map[string]any{"Code": "InvalidInstanceStatus", "Message": "sensitive-secret"}}}} {
		a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
			switch action {
			case "DescribeInstances":
				return map[string]any{"Instances": []instance{running()}}, nil
			case "DescribeEipAddresses":
				return map[string]any{"EipAddresses": []eip{address()}}, nil
			default:
				return map[string]any{"OperationDetails": details}, nil
			}
		}}
		if _, e := release(context.Background(), a, input()); e == nil || strings.Contains(e.Error(), "sensitive-secret") {
			t.Fatalf("%v", e)
		}
	}
}
func TestCompletionRequiresBothResourcesAndPersistedIntent(t *testing.T) {
	for _, tc := range []struct {
		name     string
		intent   bool
		id       string
		ips      []eip
		want     string
		exists   bool
		queryErr bool
	}{{"both absent", true, "eip-fixture", []eip{}, "TERMINATED", true, false}, {"residual EIP", true, "eip-fixture", []eip{address()}, "EIP_RELEASE_PENDING", true, false}, {"no intent", false, "eip-fixture", []eip{}, "", false, false}, {"no saved EIP", true, "", []eip{}, "", false, false}, {"query failed", true, "eip-fixture", nil, "", false, true}} {
		t.Run(tc.name, func(t *testing.T) {
			in := input()
			in.ReleaseSubmitted = tc.intent
			in.EipID = tc.id
			a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
				if action == "DescribeInstances" {
					return map[string]any{"Instances": []instance{}}, nil
				}
				if tc.queryErr {
					return nil, errors.New("query failed")
				}
				return map[string]any{"EipAddresses": tc.ips}, nil
			}}
			r, e := describe(context.Background(), a, in, false)
			if tc.queryErr {
				if e == nil {
					t.Fatal("accepted failed query")
				}
				return
			}
			if e != nil || r.State != tc.want || r.Exists != tc.exists {
				t.Fatalf("%+v %v", r, e)
			}
		})
	}
}
func TestRecoverRequiresUniqueOwnershipAndNeverPurchases(t *testing.T) {
	for _, rows := range [][]instance{{running()}, {running(), running()}, {func() instance { i := running(); i.Tags = nil; return i }()}} {
		a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
			if action != "DescribeInstances" {
				t.Fatal(action)
			}
			if q.Has("InstanceIds.1") || q.Get("TagFilters.2.Values.1") != fixtureToken {
				t.Fatal(q)
			}
			return map[string]any{"Instances": rows}, nil
		}}
		i, e := query(context.Background(), a, input(), true)
		if (len(rows) == 1 && rows[0].Tags != nil) != (e == nil && i != nil) {
			t.Fatalf("%+v %v", i, e)
		}
	}
}

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestClientUsesTLSFixedHostSignedNonReplayablePOST(t *testing.T) {
	c := newClient("fixture-id", "sensitive-secret")
	tr := c.http.Transport.(*http.Transport)
	if tr.TLSClientConfig.InsecureSkipVerify || tr.TLSClientConfig.MinVersion < tls.VersionTLS12 {
		t.Fatal("TLS")
	}
	if c.http.CheckRedirect(nil, nil) != http.ErrUseLastResponse {
		t.Fatal("redirect")
	}
	now := time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC)
	c.now = func() time.Time { return now }
	c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		b, _ := io.ReadAll(r.Body)
		if r.Method != "POST" || r.URL.Scheme != "https" || r.URL.Host != "ecs.cn-beijing.volcengineapi.com" || r.GetBody != nil || r.URL.Query().Get("Action") != "RunInstances" || r.URL.Query().Has("InstanceName") || string(b) != "InstanceName=%E6%B5%8B%E8%AF%95+fixture" || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
			t.Fatalf("unexpected request %s %s %q", r.Method, r.URL, b)
		}
		if r.Header.Get("Authorization") != authorization("fixture-id", "sensitive-secret", "ecs", "cn-beijing", r.URL.Host, r.Method, r.URL.RawQuery, string(b), now) {
			t.Fatal("signature")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"ResponseMetadata":{"RequestId":"request-1","Action":"RunInstances","Version":"2020-04-01","Service":"ecs","Region":"cn-beijing"},"Result":{"InstanceIds":["i-fixture"]}}`)), Header: http.Header{}}, nil
	})
	var out struct {
		InstanceIds []string
		RequestID   string `json:"RequestId"`
	}
	if e := c.call(context.Background(), "ecs", "RunInstances", "cn-beijing", params("InstanceName", "测试 fixture"), &out); e != nil || out.RequestID != "request-1" {
		t.Fatal(e, out)
	}
	if e := c.call(context.Background(), "evil", "RunInstances", "cn-beijing", nil, &out); e == nil {
		t.Fatal("invalid service")
	}
	if e := c.call(context.Background(), "ecs", "RunInstances", "evil.example", nil, &out); e == nil {
		t.Fatal("invalid region")
	}
}
func TestClientErrorsNeverExposeUpstreamBodyOrTransport(t *testing.T) {
	for _, body := range []string{`sensitive-secret`, `{"ResponseMetadata":{"RequestId":"request-1","Action":"RunInstances","Version":"2020-04-01","Service":"ecs","Region":"cn-beijing","Error":{"Code":"InvalidArgument","Message":"sensitive-secret"}}}`, `{"ResponseMetadata":{"RequestId":"request-1","Action":"RunInstances","Version":"2020-04-01","Service":"ecs","Region":"cn-beijing","Error":{"Code":"InvalidArgument"}},"Result":{"InstanceIds":["i-fixture"]}}`} {
		c := newClient("fixture-id", "sensitive-secret")
		c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 400, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
		})
		var out any
		e := c.call(context.Background(), "ecs", "RunInstances", "cn-beijing", nil, &out)
		if e == nil || strings.Contains(e.Error(), "sensitive-secret") {
			t.Fatal(e)
		}
	}
	c := newClient("fixture-id", "sensitive-secret")
	c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) { return nil, errors.New("sensitive-secret") })
	var out any
	if e := c.call(context.Background(), "ecs", "RunInstances", "cn-beijing", nil, &out); e == nil || strings.Contains(e.Error(), "sensitive-secret") {
		t.Fatal(e)
	}
}

func TestCredentialRejectionsAreNotReportedAsTemplateErrors(t *testing.T) {
	for _, code := range []string{"InvalidCredential", "InvalidAccessKey", "InvalidAccessKeyId", "InvalidSignature", "SignatureDoesNotMatch"} {
		if got := (&apiError{code}).Error(); !strings.Contains(got, "身份或权限") || strings.Contains(got, "资源参数") {
			t.Errorf("credential rejection %s misclassified: %s", code, got)
		}
	}
	if got := (&apiError{"InvalidVpcId.Malformed"}).Error(); !strings.Contains(got, "资源参数") {
		t.Fatal("resource parameter rejection misclassified", got)
	}
}

func TestKeyVerificationRejectsOtherFingerprint(t *testing.T) {
	r, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	k, e := ssh.NewPublicKey(&r.PublicKey)
	if e != nil {
		t.Fatal(e)
	}
	for _, finger := range []string{normalizedMD5(ssh.FingerprintLegacyMD5(k)), strings.Repeat("0", 32)} {
		a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
			if action != "DescribeKeyPairs" {
				t.Fatal("unexpected mutation", action)
			}
			return map[string]any{"KeyPairs": []any{map[string]any{"KeyPairId": "kp-fixture", "KeyPairName": cloudKeyName(k), "FingerPrint": finger, "Tags": []tag{{managedTag, managedValue}}}}}, nil
		}}
		id, e := ensureKey(context.Background(), a, "cn-beijing", k)
		if (finger != strings.Repeat("0", 32)) != (e == nil && id == cloudKeyName(k)) {
			t.Fatal(id, e)
		}
	}
}

func TestPrepareImportsPublicKeyCreatesGroupAndWaitsForRules(t *testing.T) {
	r, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	k, e := ssh.NewPublicKey(&r.PublicKey)
	if e != nil {
		t.Fatal(e)
	}
	keyCreated, groupCreated := false, false
	policies := []policy{{Direction: "egress", Protocol: "all", Policy: "accept", CidrIp: "0.0.0.0/0", Priority: 100, PortStart: -1, PortEnd: -1}}
	imports, groups, rules := 0, 0, 0
	a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
		switch action {
		case "DescribeKeyPairs":
			rows := []any{}
			if keyCreated {
				rows = append(rows, map[string]any{"KeyPairId": "kp-fixture", "KeyPairName": cloudKeyName(k), "FingerPrint": normalizedMD5(ssh.FingerprintLegacyMD5(k)), "Tags": []tag{{managedTag, managedValue}}})
			}
			return map[string]any{"KeyPairs": rows}, nil
		case "ImportKeyPair":
			imports++
			keyCreated = true
			if q.Get("PublicKey") != strings.TrimSpace(string(ssh.MarshalAuthorizedKey(k))) || q.Get("KeyPairName") != cloudKeyName(k) || q.Get("Tags.1.Value") != managedValue {
				t.Fatal(q)
			}
			return map[string]any{"KeyPairName": cloudKeyName(k), "FingerPrint": normalizedMD5(ssh.FingerprintLegacyMD5(k))}, nil
		case "DescribeSecurityGroups":
			rows := []group{}
			if groupCreated {
				rows = append(rows, validGroup())
			}
			return map[string]any{"SecurityGroups": rows}, nil
		case "CreateSecurityGroup":
			groups++
			groupCreated = true
			if q.Get("VpcId") != "vpc-fixture" || q.Get("SecurityGroupName") != groupName || q.Get("Description") != groupDescription {
				t.Fatal(q)
			}
			return map[string]any{"SecurityGroupId": "sg-fixture"}, nil
		case "DescribeSecurityGroupAttributes":
			g := validGroup()
			g.Permissions = &policies
			return g, nil
		case "AuthorizeSecurityGroupIngress":
			rules++
			port := 22
			if q.Get("PortStart") == "20001" {
				port = 20001
			}
			if q.Get("Protocol") != "tcp" || q.Get("CidrIp") != "0.0.0.0/0" || q.Get("SecurityGroupId") != "sg-fixture" {
				t.Fatal(q)
			}
			policies = append(policies, policy{Direction: "ingress", Protocol: "tcp", Policy: "accept", CidrIp: "0.0.0.0/0", Priority: 1, PortStart: port, PortEnd: port})
			return map[string]any{}, nil
		default:
			return purchaseRead(action)
		}
	}}
	in := input()
	in.PublicKey = string(ssh.MarshalAuthorizedKey(k))
	result, e := prepare(context.Background(), a, fixture(t), in)
	if e != nil || result.KeyID != cloudKeyName(k) || result.SecurityGroupID != "sg-fixture" || imports != 1 || groups != 1 || rules != 2 {
		t.Fatal(result, e, imports, groups, rules)
	}
}
