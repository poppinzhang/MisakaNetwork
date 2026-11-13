package aliyun

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"testing"
)

type networkHarness struct {
	vpcs, subnets []map[string]any
	writes        int
	lost, unseen  bool
}

func (h *networkHarness) api(t *testing.T) fake {
	return fake(func(_ context.Context, service, a, region string, p url.Values, o any) error {
		if service != "vpc" || region != "cn-hangzhou" {
			t.Fatalf("scope %s %s", service, region)
		}
		switch a {
		case "DescribeVpcs":
			return put(o, page(p, "Vpcs", "Vpc", append([]map[string]any{}, h.vpcs...), len(h.vpcs)))
		case "DescribeVSwitches":
			return put(o, page(p, "VSwitches", "VSwitch", append([]map[string]any{}, h.subnets...), len(h.subnets)))
		case "CreateVpc", "CreateVSwitch":
			h.writes++
			if !tokenPattern.MatchString(p.Get("ClientToken")) || p.Get("Tag.1.Key") != managedTag || p.Get("Tag.2.Key") != networkTag {
				t.Fatal("missing lifecycle parameters")
			}
			if a == "CreateVpc" {
				if p.Get("VpcName") != networkVpcName || p.Get("CidrBlock") != networkVpcCIDR || p.Get("EnableIpv6") != "false" {
					t.Fatal(p)
				}
				if !h.unseen {
					h.vpcs = append(h.vpcs, fixtureVpc())
				}
				if h.lost {
					return errors.New("response lost")
				}
				return put(o, map[string]any{"VpcId": "vpc-fixture"})
			}
			if p.Get("VpcId") != "vpc-fixture" || p.Get("VSwitchName") != subnetName(p.Get("ZoneId")) {
				t.Fatal(p)
			}
			row := fixtureSubnet()
			id := fmt.Sprintf("vsw-fixture%d", len(h.subnets))
			row["VSwitchId"] = id
			row["ZoneId"] = p.Get("ZoneId")
			row["VSwitchName"] = p.Get("VSwitchName")
			row["CidrBlock"] = p.Get("CidrBlock")
			if !h.unseen {
				h.subnets = append(h.subnets, row)
			}
			if h.lost {
				return errors.New("response lost")
			}
			return put(o, map[string]any{"VSwitchId": id})
		default:
			t.Fatalf("unexpected %s", a)
		}
		return nil
	})
}
func TestNetworksCreateReuseAndZoneSubnetAllocation(t *testing.T) {
	h := &networkHarness{}
	api := h.api(t)
	f := fixture()
	in := Input{SecretID: "fixture", NetworkKind: "vpc"}
	for range 2 {
		r := createNetwork(context.Background(), api, f, in)
		if r.State != "ready" || r.VpcID != "vpc-fixture" {
			t.Fatalf("%+v", r)
		}
	}
	if h.writes != 1 {
		t.Fatal(h.writes)
	}
	in.NetworkKind = "subnet"
	in.VpcID = "vpc-fixture"
	for n, zone := range []string{"cn-hangzhou-h", "cn-hangzhou-i"} {
		f.RunInstances.ZoneID = zone
		in.SubnetCIDR = ""
		r, e := lookupNetwork(context.Background(), api, f, in)
		if e != nil || r.Found || r.SubnetCIDR != fmt.Sprintf("10.8.%d.0/24", n) {
			t.Fatalf("%+v %v", r, e)
		}
		in.SubnetCIDR = r.SubnetCIDR
		for range 2 {
			c := createNetwork(context.Background(), api, f, in)
			if c.State != "ready" || c.SubnetID != fmt.Sprintf("vsw-fixture%d", n) {
				t.Fatalf("%+v", c)
			}
		}
	}
	if h.writes != 3 {
		t.Fatal(h.writes)
	}
}
func TestNetworkUnknownPreservesIDAndNeverRecreates(t *testing.T) {
	for _, lost := range []bool{false, true} {
		h := &networkHarness{unseen: true, lost: lost}
		in := Input{SecretID: "fixture", NetworkKind: "vpc"}
		r := createNetwork(context.Background(), h.api(t), fixture(), in)
		if r.State != "unknown" || h.writes != 1 {
			t.Fatalf("%+v", r)
		}
		if !lost && r.VpcID != "vpc-fixture" {
			t.Fatal("ID lost")
		}
		in.VpcID = "vpc-fixture"
		r = createNetwork(context.Background(), h.api(t), fixture(), in)
		if r.State != "unknown" || h.writes != 1 {
			t.Fatalf("recreated %+v", r)
		}
	}
	h := &networkHarness{lost: true}
	r := createNetwork(context.Background(), h.api(t), fixture(), Input{NetworkKind: "vpc"})
	if r.State != "ready" || h.writes != 1 {
		t.Fatalf("query did not recover lost response %+v", r)
	}
}
func TestNetworkRejectsForeignPendingOverlapsAndSavedIDChange(t *testing.T) {
	for _, scenario := range []string{"foreign", "wrong-id", "wrong-cidr", "duplicate", "pending"} {
		t.Run(scenario, func(t *testing.T) {
			v := fixtureVpc()
			in := Input{NetworkKind: "vpc"}
			h := &networkHarness{vpcs: []map[string]any{v}}
			switch scenario {
			case "foreign":
				v["Tags"] = nil
			case "wrong-id":
				in.VpcID = "vpc-other"
			case "wrong-cidr":
				v["CidrBlock"] = "10.9.0.0/16"
			case "duplicate":
				v2 := fixtureVpc()
				v2["VpcId"] = "vpc-other"
				h.vpcs = append(h.vpcs, v2)
			case "pending":
				v["Status"] = "Pending"
			}
			r, e := lookupNetwork(context.Background(), h.api(t), fixture(), in)
			if scenario == "pending" {
				if e != nil || r.Found || r.VpcID != "vpc-fixture" {
					t.Fatalf("pending %+v %v", r, e)
				}
			} else if e == nil {
				t.Fatal("conflict accepted")
			}
			createNetwork(context.Background(), h.api(t), fixture(), in)
			if h.writes != 0 {
				t.Fatal("mutation on conflict/pending")
			}
		})
	}
	h := &networkHarness{vpcs: []map[string]any{fixtureVpc()}, subnets: []map[string]any{fixtureSubnet(), fixtureSubnet()}}
	_, e := lookupNetwork(context.Background(), h.api(t), fixture(), Input{NetworkKind: "subnet", VpcID: "vpc-fixture"})
	if e == nil {
		t.Fatal("overlap accepted")
	}
}
func TestNetworkRejectionDoesNotForgetPartialSuccess(t *testing.T) {
	for _, code := range []string{"Forbidden.RAM", "InternalError", "InvalidTag"} {
		h := &networkHarness{}
		base := h.api(t)
		api := fake(func(c context.Context, s, a, r string, p url.Values, o any) error {
			if a == "CreateVpc" {
				h.writes++
				return &apiError{code}
			}
			return base.call(c, s, a, r, p, o)
		})
		r := createNetwork(context.Background(), api, fixture(), Input{NetworkKind: "vpc"})
		want := "unknown"
		if code == "Forbidden.RAM" {
			want = "rejected"
		}
		if r.State != want || h.writes != 1 {
			t.Fatalf("%s %+v", code, r)
		}
	}
}
