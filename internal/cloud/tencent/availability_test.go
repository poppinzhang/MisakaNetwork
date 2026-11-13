package tencent

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func quotaRow(zone, instanceType, billing, status string) map[string]any {
	return map[string]any{"Zone": zone, "InstanceType": instanceType, "InstanceChargeType": billing, "Status": status}
}

func TestAvailableZonesUsesExactTypeBillingAndRegion(t *testing.T) {
	template := fixtureTemplate()
	template.RunInstances.InstanceType = "S5se.LARGE16"
	in := fixtureInput()
	in.Template, _ = json.Marshal(template)
	api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
		if c.service != "cvm" || c.action != "DescribeZoneInstanceConfigInfos" || c.region != template.Region {
			t.Fatal("inventory request escaped selected service or region")
		}
		want := map[string]any{"Filters": []any{filter("instance-type", "S5se.LARGE16"), filter("instance-charge-type", "POSTPAID_BY_HOUR")}}
		gotJSON, _ := json.Marshal(c.body)
		wantJSON, _ := json.Marshal(want)
		if string(gotJSON) != string(wantJSON) {
			t.Fatal("query did not use exact type and billing filters without a zone restriction")
		}
		return map[string]any{"InstanceTypeQuotaSet": []any{
			quotaRow("ap-guangzhou-7", "S5se.LARGE16", "POSTPAID_BY_HOUR", "SELL"),
			quotaRow("ap-guangzhou-4", "S5se.LARGE16", "POSTPAID_BY_HOUR", "SELL"),
			quotaRow("ap-guangzhou-4", "S5se.LARGE16", "POSTPAID_BY_HOUR", "SELL"),
			quotaRow("ap-guangzhou-3", "S5se.LARGE16", "POSTPAID_BY_HOUR", "SOLD_OUT"),
			quotaRow("ap-guangzhou-3", "S5se.LARGE16", "POSTPAID_BY_HOUR", "SELL"),
			quotaRow("ap-guangzhou-2", "S5se.LARGE16", "POSTPAID_BY_HOUR", "SELL"),
			quotaRow("ap-guangzhou-2", "S5se.LARGE16", "POSTPAID_BY_HOUR", "SOLD_OUT"),
			quotaRow("ap-guangzhou-6", "S5se.LARGE16", "PREPAID", "SELL"),
			quotaRow("ap-guangzhou-5", "S5SE.LARGE16", "POSTPAID_BY_HOUR", "SELL"),
			quotaRow("ap-guangzhou-1", "S5se.LARGE16", "POSTPAID_BY_HOUR", "UNKNOWN"),
		}}, nil
	}}
	result, err := execute(context.Background(), api, "tencent_zones", in)
	if err != nil || !reflect.DeepEqual(result.(AvailableZones).Zones, []string{"ap-guangzhou-4", "ap-guangzhou-7"}) || len(api.calls) != 1 {
		t.Fatalf("inventory filtering failed: %+v %v", result, err)
	}
}

func TestAvailableZonesRejectsInvalidResponsesAndPreservesEmptyInventory(t *testing.T) {
	for _, scenario := range []string{"missing", "null", "wrong-type", "cross-region", "invalid-zone", "transport", "empty"} {
		t.Run(scenario, func(t *testing.T) {
			api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
				switch scenario {
				case "missing":
					return map[string]any{}, nil
				case "null":
					return map[string]any{"InstanceTypeQuotaSet": nil}, nil
				case "wrong-type":
					return map[string]any{"InstanceTypeQuotaSet": "SELL"}, nil
				case "transport":
					return nil, errors.New("response lost")
				case "empty":
					return map[string]any{"InstanceTypeQuotaSet": []any{}}, nil
				default:
					zone := "ap-shanghai-1"
					if scenario == "invalid-zone" {
						zone = "ap-guangzhou-7\n"
					}
					return map[string]any{"InstanceTypeQuotaSet": []any{quotaRow(zone, "S5.MEDIUM4", "POSTPAID_BY_HOUR", "SELL")}}, nil
				}
			}}
			result, err := execute(context.Background(), api, "tencent_zones", fixtureInput())
			if scenario == "empty" {
				encoded, _ := json.Marshal(result)
				if err != nil || string(encoded) != `{"zones":[]}` {
					t.Fatalf("empty inventory must remain valid and explicit: %s %v", encoded, err)
				}
			} else if err == nil {
				t.Fatal("invalid or uncertain inventory accepted")
			}
			if len(api.calls) != 1 {
				t.Fatal("inventory lookup unexpectedly retried")
			}
		})
	}
}

func createFixtureResponse(t *testing.T, c callRecord) (any, error) {
	t.Helper()
	switch c.action {
	case "DescribeImages":
		return imageResponse(), nil
	case "DescribeSecurityGroupPolicies":
		return policyResponse(), nil
	case "DescribeVpcs":
		return vpcResponse(ownedVpc()), nil
	case "DescribeSubnets":
		return subnetResponse(ownedSubnet(fixtureTemplate(), "subnet-fixture", "10.8.0.0/24")), nil
	default:
		t.Fatalf("unexpected preflight action %s", c.action)
		return nil, nil
	}
}

func TestOnlyExplicitPurchaseAvailabilityRefusalsPermitFallback(t *testing.T) {
	allowed := []string{
		"ResourceInsufficient.AvailabilityZoneSoldOut", "ResourceInsufficient.CloudDiskSoldOut",
		"ResourceInsufficient.InsufficientOfferingMinimum", "ResourceInsufficient.SpecifiedInstanceType",
		"ResourceUnavailable.InstanceType", "ResourcesSoldOut.SpecifiedInstanceType", "InvalidParameterValue.ZoneNotSupported",
	}
	disallowed := []string{
		"ResourceInsufficient", "ResourceInsufficient.CloudDiskUnavailable", "ResourceInsufficient.CidrBlock",
		"ResourceInsufficient.DisasterRecoverGroupCvmQuota", "ResourceUnavailable", "ResourcesSoldOut.EipInsufficient",
		"AuthFailure.SignatureFailure", "UnauthorizedOperation", "LimitExceeded.InstanceQuota",
		"InvalidAccount.InsufficientBalance", "InsufficientFunds", "InternalError.TradeUnknownError",
		"InvalidParameterValue.InstanceTypeNotFound", "InvalidZone.MismatchRegion", "FailedOperation.IllegalTagValue",
		"ResourceInsufficient.SpecifiedInstanceType.extra", "resourceinsufficient.specifiedinstancetype", "",
	}
	for _, code := range append(append([]string{}, allowed...), disallowed...) {
		t.Run(code, func(t *testing.T) {
			wantUnavailable := false
			for _, allowedCode := range allowed {
				wantUnavailable = wantUnavailable || code == allowedCode
			}
			api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
				if c.action == "RunInstances" {
					return nil, &apiError{code: code}
				}
				return createFixtureResponse(t, c)
			}}
			result, err := create(context.Background(), api, fixtureTemplate(), fixtureInput())
			if (err == nil) != wantUnavailable || (result.State == "unavailable") != wantUnavailable || result.InstanceID != "" {
				t.Fatalf("unsafe purchase classification: %+v %v", result, err)
			}
			purchases := 0
			for _, call := range api.calls {
				if call.action == "RunInstances" {
					purchases++
				}
			}
			if purchases != 1 {
				t.Fatal("adapter retried or skipped purchase")
			}
		})
	}
	if zoneUnavailable(errors.New("ResourceInsufficient.SpecifiedInstanceType")) {
		t.Fatal("untyped text permitted fallback")
	}
}

func TestAvailabilityErrorsOutsidePurchaseDoNotPermitFallback(t *testing.T) {
	for _, action := range []string{"DescribeImages", "DescribeSecurityGroupPolicies", "DescribeVpcs", "DescribeSubnets"} {
		t.Run(action, func(t *testing.T) {
			api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
				if c.action == action {
					return nil, &apiError{code: "ResourceInsufficient.SpecifiedInstanceType"}
				}
				return createFixtureResponse(t, c)
			}}
			result, err := create(context.Background(), api, fixtureTemplate(), fixtureInput())
			if err == nil || result.State == "unavailable" {
				t.Fatal("preflight error authorized a fallback purchase")
			}
		})
	}
}

func TestMalformedOrConflictingPurchaseErrorCannotPermitFallback(t *testing.T) {
	for _, body := range []string{
		`{"Response":{"Error":{"Code":"ResourceInsufficient.SpecifiedInstanceType"}}}`,
		`{"Response":{"Error":{"Code":"ResourceInsufficient.SpecifiedInstanceType"},"RequestId":"invalid\nrequest"}}`,
		`{"Response":{"Error":{"Code":"ResourceInsufficient.SpecifiedInstanceType"},"RequestId":"valid-request","InstanceIdSet":["ins-fixture"]}}`,
		`{"Response":{"Error":{"Code":"ResourceInsufficient.SpecifiedInstanceType"},"RequestId":"valid-request","InstanceIdSet":[]}}`,
	} {
		c := newClient("fixture-id", "fixture-secret")
		c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		})
		var out map[string]any
		err := c.call(context.Background(), "cvm", "RunInstances", "ap-guangzhou", map[string]any{}, &out)
		if err == nil || zoneUnavailable(err) {
			t.Fatal("ambiguous purchase error permitted fallback")
		}
	}
}
