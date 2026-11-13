package aliyun

import (
	"context"
	"errors"
	"net/url"
	"reflect"
	"testing"
)

func zone(region, id, kind, status, category string) map[string]any {
	return map[string]any{"RegionId": region, "ZoneId": id, "Status": "Available", "StatusCategory": "WithStock", "AvailableResources": map[string]any{"AvailableResource": []any{map[string]any{"Type": "InstanceType", "SupportedResources": map[string]any{"SupportedResource": []any{map[string]any{"Value": kind, "Status": status, "StatusCategory": category}}}}}}}
}
func TestAvailabilityExactTypeRegionAndConflictingDuplicates(t *testing.T) {
	f := fixture()
	rows := []any{zone(f.Region, "cn-hangzhou-h", f.RunInstances.InstanceType, "Available", "WithStock"), zone(f.Region, "cn-hangzhou-i", "ecs.other.large", "Available", "WithStock"), zone(f.Region, "cn-hangzhou-j", f.RunInstances.InstanceType, "Available", "WithStock"), zone(f.Region, "cn-hangzhou-j", f.RunInstances.InstanceType, "SoldOut", "WithoutStock")}
	api := fake(func(_ context.Context, s, a, r string, p url.Values, o any) error {
		if s != "ecs" || a != "DescribeAvailableResource" || r != f.Region || p.Get("InstanceType") != f.RunInstances.InstanceType || p.Get("InstanceChargeType") != "PostPaid" || p.Get("SpotStrategy") != "NoSpot" || p.Has("ZoneId") || p.Has("SystemDiskCategory") {
			t.Fatal(p)
		}
		return put(o, map[string]any{"AvailableZones": map[string]any{"AvailableZone": rows}})
	})
	r, e := availableZones(context.Background(), api, f)
	if e != nil || !reflect.DeepEqual(r.Zones, []string{"cn-hangzhou-h"}) {
		t.Fatalf("%+v %v", r, e)
	}
	f.Region = "ap-southeast-1"
	rows = []any{zone(f.Region, "ap-southeast-1a", f.RunInstances.InstanceType, "Available", "WithStock")}
	r, e = availableZones(context.Background(), api, f)
	if e != nil || len(r.Zones) != 1 {
		t.Fatalf("overseas %+v %v", r, e)
	}
	rows = []any{zone("cn-hangzhou", "cn-hangzhou-h", f.RunInstances.InstanceType, "Available", "WithStock")}
	if _, e = availableZones(context.Background(), api, f); e == nil {
		t.Fatal("cross-region accepted")
	}
}
func TestAvailabilityMalformedAndNonCapacityErrors(t *testing.T) {
	for _, v := range []any{map[string]any{}, map[string]any{"AvailableZones": map[string]any{"AvailableZone": nil}}, map[string]any{"AvailableZones": map[string]any{"AvailableZone": []any{map[string]any{"RegionId": "cn-hangzhou", "ZoneId": "cn-hangzhou-h"}}}}} {
		api := fake(func(_ context.Context, _, _, _ string, _ url.Values, o any) error { return put(o, v) })
		if _, e := availableZones(context.Background(), api, fixture()); e == nil {
			t.Fatal(v)
		}
	}
	for _, code := range []string{"QuotaExceed.DiskCapacity", "InsufficientBalance", "Forbidden.RAM", "OperationDenied", "InvalidParameter", "InternalError", "OperationDenied.ResourceControl"} {
		if zoneUnavailable(&apiError{code}) {
			t.Fatal(code)
		}
	}
	if zoneUnavailable(errors.New("OperationDenied.NoStock")) {
		t.Fatal("raw message parsed")
	}
}
func TestSecurityGroupRulesFailClosed(t *testing.T) {
	for _, mutate := range []func(*permission){func(p *permission) { p.PortRange = "1/65535" }, func(p *permission) { p.SourceCidrIp = "10.0.0.0/8" }, func(p *permission) { p.SourceGroupId = "sg-external" }, func(p *permission) { p.Policy = "Drop" }, func(p *permission) { p.NicType = "internet" }, func(p *permission) { p.SourcePrefixListId = "pl-external" }, func(p *permission) { p.Priority = "0" }} {
		rules := fixtureRules()
		mutate(&rules[0])
		if _, e := missingRules(rules); e == nil {
			t.Fatal("unsafe rule accepted")
		}
	}
	rules := fixtureRules()
	rules = append(rules, rules[0])
	if _, e := missingRules(rules); e == nil {
		t.Fatal("duplicate rule accepted")
	}
}

func TestRuleWritesUseModernPermissionsAndWaitForVisibility(t *testing.T) {
	rules := []permission{}
	writes := 0
	api := fake(func(_ context.Context, s, a, r string, p url.Values, o any) error {
		if a == "DescribeSecurityGroupAttribute" {
			return put(o, map[string]any{"SecurityGroupId": "sg-fixture", "VpcId": "vpc-fixture", "SecurityGroupName": groupName, "Description": groupDescription, "InnerAccessPolicy": "Accept", "Permissions": map[string]any{"Permission": rules}})
		}
		if a != "AuthorizeSecurityGroup" && a != "AuthorizeSecurityGroupEgress" {
			t.Fatal(a)
		}
		writes++
		for _, k := range []string{"IpProtocol", "Policy", "PortRange", "SourceCidrIp", "DestCidrIp"} {
			if p.Has(k) {
				t.Fatal("deprecated parameter " + k)
			}
		}
		if p.Get("Permissions.1.Policy") != "accept" || p.Get("Permissions.1.Priority") != "1" || p.Get("Permissions.1.NicType") != "intranet" {
			t.Fatal(p)
		}
		rule := permission{Policy: "Accept", NicType: "intranet", Priority: "1", Direction: "ingress", IpProtocol: p.Get("Permissions.1.IpProtocol"), PortRange: p.Get("Permissions.1.PortRange"), SourceCidrIp: p.Get("Permissions.1.SourceCidrIp"), DestCidrIp: p.Get("Permissions.1.DestCidrIp")}
		if a == "AuthorizeSecurityGroupEgress" {
			rule.Direction = "egress"
		}
		rules = append(rules, rule)
		// Lost write responses are recovered through read-only rule checks.
		return errors.New("response lost")
	})
	if e := reconcileRules(context.Background(), api, fixture(), "vpc-fixture", "sg-fixture", true); e != nil || writes != 3 {
		t.Fatalf("rules %d %v", writes, e)
	}
	if e := reconcileRules(context.Background(), api, fixture(), "vpc-fixture", "sg-fixture", true); e != nil || writes != 3 {
		t.Fatalf("rules recreated %d %v", writes, e)
	}
}

func TestImageRejectsDataDisksAndInvalidMappingsBeforeWrites(t *testing.T) {
	for _, mappings := range []any{nil, map[string]any{"DiskDeviceMapping": []any{}}, map[string]any{"DiskDeviceMapping": []any{map[string]any{"Type": "system", "Size": "20"}, map[string]any{"Type": "data", "Size": "100"}}}, map[string]any{"DiskDeviceMapping": []any{map[string]any{"Type": "system", "Size": "200"}}}} {
		k := fixtureKey(t)
		api := fixtureAPI(t, k, func(a string, p url.Values, v map[string]any) error {
			if a != "DescribeImages" {
				t.Fatalf("image failure allowed %s", a)
			}
			v["Images"].(map[string]any)["Image"].([]map[string]any)[0]["DiskDeviceMappings"] = mappings
			v["Images"].(map[string]any)["Image"].([]map[string]any)[0]["ImageOwnerAlias"] = "self"
			return nil
		})
		if e := preflightImage(context.Background(), api, fixture()); e == nil {
			t.Fatal("unsafe image mapping")
		}
	}
}
