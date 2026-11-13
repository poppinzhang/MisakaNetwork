package volcengine

import (
	"context"
	"errors"
	"net/netip"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestNetworkPaginationBeforeSubnetPlanning(t *testing.T) {
	a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
		if action == "DescribeVpcs" {
			return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
		}
		s := validSubnet()
		s.SubnetName = "unrelated"
		if q.Get("NextToken") == "" {
			return map[string]any{"Subnets": []networkSubnet{s}, "NextToken": "second"}, nil
		}
		s.SubnetID = "subnet-second"
		s.CidrBlock = "10.8.1.0/24"
		return map[string]any{"Subnets": []networkSubnet{s}}, nil
	}}
	in := input()
	in.SubnetID = ""
	in.SubnetCIDR = ""
	in.NetworkKind = "subnet"
	r, e := lookupNetwork(context.Background(), a, fixture(t), in)
	if e != nil || r.Found || r.SubnetCIDR != "10.8.2.0/24" {
		t.Fatalf("%+v %v", r, e)
	}
}
func TestNetworkPaginationRejectsRepeatedTokensMissingListsAndDuplicateIDs(t *testing.T) {
	for _, mode := range []string{"token-loop", "missing-list", "duplicate-subnet"} {
		t.Run(mode, func(t *testing.T) {
			a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
				if action == "DescribeVpcs" {
					return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
				}
				switch mode {
				case "token-loop":
					s := validSubnet()
					s.SubnetName = "other"
					return map[string]any{"Subnets": []networkSubnet{s}, "NextToken": "same"}, nil
				case "missing-list":
					return map[string]any{}, nil
				default:
					return map[string]any{"Subnets": []networkSubnet{validSubnet(), validSubnet()}}, nil
				}
			}}
			if _, _, e := lookupSubnet(context.Background(), a, fixture(t), "vpc-fixture"); e == nil {
				t.Fatal("accepted")
			}
		})
	}
}
func TestNetworkConflictNeverMutates(t *testing.T) {
	for _, mode := range []string{"foreign-tags", "different-cidr", "default-vpc", "different-id", "multiple"} {
		t.Run(mode, func(t *testing.T) {
			v := validVpc()
			switch mode {
			case "foreign-tags":
				v.Tags = nil
			case "different-cidr":
				v.CidrBlock = "10.9.0.0/16"
			case "default-vpc":
				v.IsDefault = true
			case "different-id":
				v.VpcID = "vpc-other"
			}
			rows := []networkVpc{v}
			if mode == "multiple" {
				rows = append(rows, v)
			}
			a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
				if action != "DescribeVpcs" {
					t.Fatal("unexpected mutation", action)
				}
				return map[string]any{"Vpcs": rows}, nil
			}}
			in := input()
			in.NetworkKind = "vpc"
			r := createNetwork(context.Background(), a, fixture(t), in)
			if r.State != "rejected" {
				t.Fatal(r)
			}
		})
	}
}
func TestPendingNetworkNeverRecreated(t *testing.T) {
	for _, tc := range []struct{ kind, status string }{{"vpc", "Creating"}, {"vpc", "Pending"}, {"subnet", "Pending"}} {
		t.Run(tc.kind+"/"+tc.status, func(t *testing.T) {
			a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
				switch action {
				case "DescribeVpcs":
					v := validVpc()
					if tc.kind == "vpc" {
						v.Status = tc.status
					}
					return map[string]any{"Vpcs": []networkVpc{v}}, nil
				case "DescribeSubnets":
					s := validSubnet()
					s.Status = tc.status
					return map[string]any{"Subnets": []networkSubnet{s}}, nil
				default:
					t.Fatal("mutation", action)
					return nil, nil
				}
			}}
			in := input()
			in.NetworkKind = tc.kind
			if tc.kind == "vpc" {
				in.VpcID = ""
			} else {
				in.SubnetID = ""
			}
			r := createNetwork(context.Background(), a, fixture(t), in)
			if r.State != "unknown" || r.VpcID != "vpc-fixture" {
				t.Fatal(r)
			}
		})
	}
}
func TestCreateNetworkKeepsKnownIDUntilVisible(t *testing.T) {
	a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
		switch action {
		case "DescribeVpcs":
			return map[string]any{"Vpcs": []networkVpc{}}, nil
		case "CreateVpc":
			for k, w := range map[string]string{"VpcName": networkVpcName, "CidrBlock": networkVpcCIDR, "Tags.1.Key": managedTag, "Tags.2.Value": networkValue} {
				if q.Get(k) != w {
					t.Fatal(q)
				}
			}
			if !tokenPattern.MatchString(q.Get("ClientToken")) {
				t.Fatal("token")
			}
			return map[string]any{"VpcId": "vpc-known"}, nil
		default:
			t.Fatal(action)
			return nil, nil
		}
	}}
	in := input()
	in.VpcID = ""
	in.NetworkKind = "vpc"
	r := createNetwork(context.Background(), a, fixture(t), in)
	if r.State != "unknown" || r.VpcID != "vpc-known" {
		t.Fatal(r)
	}
}
func TestCreateNetworkDistinguishesLostResponseFromRejection(t *testing.T) {
	for _, tc := range []struct {
		err   error
		state string
	}{{errors.New("response lost"), "unknown"}, {&apiError{"Forbidden"}, "rejected"}, {&apiError{"InvalidTagKey.Malformed"}, "unknown"}} {
		a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
			if action == "DescribeVpcs" {
				return map[string]any{"Vpcs": []networkVpc{}}, nil
			}
			return nil, tc.err
		}}
		in := input()
		in.VpcID = ""
		in.NetworkKind = "vpc"
		r := createNetwork(context.Background(), a, fixture(t), in)
		if r.State != tc.state {
			t.Fatalf("%+v", r)
		}
	}
}
func TestSubnetAllocationAvoidsOverlappingLargerBlocks(t *testing.T) {
	used := []netip.Prefix{netip.MustParsePrefix("10.8.0.0/23"), netip.MustParsePrefix("10.8.2.0/24")}
	v, e := plannedSubnetCIDR(used)
	if e != nil || v != "10.8.3.0/24" {
		t.Fatal(v, e)
	}
	if cidrAvailable("10.9.0.0/24", nil) || cidrAvailable("10.8.1.0/24", used) {
		t.Fatal("invalid cidr accepted")
	}
}
func TestPoliciesAcceptVendorDefaultsAndRejectUnexpectedAccess(t *testing.T) {
	p := requiredPolicies()
	p = append(p, policy{Direction: "ingress", Protocol: "ALL", Policy: "accept", SourceGroupID: "sg-fixture", Priority: 1, PortStart: -1, PortEnd: -1}, policy{Direction: "egress", Protocol: "ALL", Policy: "accept", CidrIp: "::/0", Priority: 100, PortStart: -1, PortEnd: -1})
	if m, e := missingPolicies(p, "sg-fixture"); e != nil || len(m) != 0 {
		t.Fatal(m, e)
	}
	for _, bad := range []policy{{Direction: "ingress", Protocol: "all", Policy: "accept", CidrIp: "0.0.0.0/0", Priority: 1, PortStart: -1, PortEnd: -1}, {Direction: "ingress", Protocol: "all", Policy: "accept", SourceGroupID: "sg-other", Priority: 1, PortStart: -1, PortEnd: -1}, {Direction: "ingress", Protocol: "tcp", Policy: "accept", CidrIp: "0.0.0.0/0", Priority: 1, PortStart: 22, PortEnd: 22, PrefixListID: "pl-other"}} {
		if _, e := missingPolicies(append(append([]policy(nil), p...), bad), "sg-fixture"); e == nil {
			t.Fatal("accepted", bad)
		}
	}
}
func TestWaitPreparationHonorsCancellationWithoutMutations(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond)
	defer cancel()
	calls := 0
	e := waitPreparation(ctx, func(context.Context) (bool, error) { calls++; return false, nil })
	if e == nil || calls != 1 {
		t.Fatal(e, calls)
	}
}
func TestInstanceTerminalLabelCannotBypassEipConfirmation(t *testing.T) {
	a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
		if action == "DescribeInstances" {
			i := running()
			i.Status = "TERMINATED"
			return map[string]any{"Instances": []instance{i}}, nil
		}
		return map[string]any{"EipAddresses": []eip{address()}}, nil
	}}
	in := input()
	in.ReleaseSubmitted = true
	r, e := describe(context.Background(), a, in, false)
	if e != nil || r.State == "TERMINATED" || !r.Exists {
		t.Fatal(r, e)
	}
}
func TestSigningMatchesIndependentFixture(t *testing.T) {
	got := authorization("fixture-id", "sensitive-secret", "ecs", "cn-beijing", "ecs.cn-beijing.volcengineapi.com", "POST", "Action=RunInstances&Version=2020-04-01", "InstanceName=%E6%B5%8B%E8%AF%95+fixture", time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC))
	// Cross-checked with an independent Python hashlib/hmac implementation.
	if !strings.HasSuffix(got, "Signature=592b2a51b9e5ee4e2d84d60b155b8f2efcfc9df02cddfa615463fd1d1764aaee") {
		t.Fatal(got)
	}
}

func TestVPCGETSigningMatchesIndependentFixture(t *testing.T) {
	// Independently calculated with Python hashlib/hmac, following the official
	// signer (host;x-date, all parameters in the canonical query, empty body).
	got := authorization("fixture-id", "sensitive-secret", "vpc", "cn-beijing", "vpc.cn-beijing.volcengineapi.com", "GET", "Action=DescribeVpcs&MaxResults=100&Version=2020-04-01&VpcName=MisakaNetwork-VPC", "", time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC))
	want := "HMAC-SHA256 Credential=fixture-id/20261113/cn-beijing/vpc/request, SignedHeaders=host;x-date, Signature=ba38e15bba6337511e37986d90dc639ce60d25c1a489f17e5e525283f2a6fb70"
	if got != want {
		t.Fatal("VPC GET signature differs from independent fixture")
	}
}

func TestOfficialInternationalRegionsAndZones(t *testing.T) {
	for _, tc := range []struct {
		region, zone string
		valid        bool
	}{
		{"ap-southeast-1", "ap-southeast-1a", true},
		{"ap-southeast-3", "ap-southeast-3a", true},
		{"cn-beijing", "cn-beijing-a", true},
		{"ap-southeast-1", "ap-southeast-1-a", false},
		{"cn-beijing", "cn-beijinga", false},
		{"ap-southeast-1", "ap-southeast-3a", false},
	} {
		v := fixture(t)
		v.Region = tc.region
		v.RunInstances.ZoneID = tc.zone
		if (v.Validate() == nil) != tc.valid {
			t.Fatalf("region=%s zone=%s", tc.region, tc.zone)
		}
	}
}

func TestReleasePollingToleratesAsyncEipDisappearanceWithoutFinalizing(t *testing.T) {
	for _, mode := range []string{"absent", "detaching"} {
		a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
			if action == "DescribeInstances" {
				return map[string]any{"Instances": []instance{running()}}, nil
			}
			ips := []eip{}
			if mode == "detaching" {
				ip := address()
				ip.Status = "Detaching"
				ip.InstanceID = ""
				ips = append(ips, ip)
			}
			return map[string]any{"EipAddresses": ips}, nil
		}}
		in := input()
		in.ReleaseSubmitted = true
		r, e := describe(context.Background(), a, in, false)
		if e != nil || !r.Exists || r.State == "TERMINATED" || r.PublicIP != "" {
			t.Fatal(r, e)
		}
	}
}
