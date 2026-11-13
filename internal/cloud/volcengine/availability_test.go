package volcengine

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"testing"
)

type callFunc func(context.Context, string, string, string, url.Values, any) error

func (f callFunc) call(ctx context.Context, service, action, region string, in url.Values, out any) error {
	return f(ctx, service, action, region, in, out)
}

func inventoryZone(region, zone, value, status string) map[string]any {
	return map[string]any{
		"RegionId": region, "ZoneId": zone, "Status": "Available",
		"AvailableResources": []any{map[string]any{
			"Type": "InstanceType", "SupportedResources": []any{
				map[string]any{"Value": value, "Status": status},
			},
		}},
	}
}

func inventoryResult(t *testing.T, template Template, result any) (AvailableZones, error) {
	t.Helper()
	api := callFunc(func(ctx context.Context, service, action, region string, in url.Values, out any) error {
		if service != "ecs" || action != "DescribeAvailableResource" || region != template.Region {
			t.Fatalf("unexpected inventory API %s/%s/%s", service, action, region)
		}
		want := params("DestinationResource", "InstanceType", "InstanceTypeId", template.RunInstances.InstanceTypeID, "InstanceChargeType", "PostPaid", "SpotStrategy", "NoSpot")
		if !reflect.DeepEqual(in, want) {
			t.Fatalf("inventory must keep type/billing and omit ZoneId: %#v", in)
		}
		body, err := json.Marshal(result)
		if err != nil {
			t.Fatal(err)
		}
		return json.Unmarshal(body, out)
	})
	return availableZones(context.Background(), api, template)
}

func TestAvailableZonesUsesNestedExactTypeAndConservativeDuplicates(t *testing.T) {
	template := fixture(t)
	target := template.RunInstances.InstanceTypeID
	zone := func(id, value, status string) map[string]any {
		return inventoryZone(template.Region, id, value, status)
	}
	wrongGroup := zone("cn-beijing-f", target, "Available")
	wrongGroup["AvailableResources"].([]any)[0].(map[string]any)["Type"] = "DedicatedHost"
	soldOutZone := zone("cn-beijing-g", target, "Available")
	soldOutZone["Status"] = "SoldOut"
	nestedConflict := zone("cn-beijing-h", target, "Available")
	group := nestedConflict["AvailableResources"].([]any)[0].(map[string]any)
	group["SupportedResources"] = append(group["SupportedResources"].([]any), map[string]any{"Value": target, "Status": "SoldOut"})
	result, err := inventoryResult(t, template, map[string]any{"AvailableZones": []any{
		zone("cn-beijing-c", target, "Available"),
		zone("cn-beijing-a", target, "Available"),
		zone("cn-beijing-a", target, "Available"),
		zone("cn-beijing-b", target, "Available"),
		zone("cn-beijing-b", target, "SoldOut"),
		zone("cn-beijing-d", "ecs.g3i.xlarge", "Available"),
		zone("cn-beijing-e", target, "SoldOut"),
		wrongGroup, soldOutZone, nestedConflict,
	}})
	if err != nil || !reflect.DeepEqual(result.Zones, []string{"cn-beijing-a", "cn-beijing-c"}) {
		t.Fatalf("%+v %v", result, err)
	}
}

func TestAvailableZonesRejectsMalformedAndForeignInventory(t *testing.T) {
	template := fixture(t)
	for _, tc := range []struct {
		name   string
		change func(map[string]any)
	}{
		{"foreign region", func(z map[string]any) { z["RegionId"] = "cn-shanghai" }},
		{"foreign zone", func(z map[string]any) { z["ZoneId"] = "cn-shanghai-a" }},
		{"missing region", func(z map[string]any) { delete(z, "RegionId") }},
		{"bad zone", func(z map[string]any) { z["ZoneId"] = "cn-beijing-1" }},
		{"missing zone status", func(z map[string]any) { delete(z, "Status") }},
		{"unknown zone status", func(z map[string]any) { z["Status"] = "Unknown" }},
		{"missing groups", func(z map[string]any) { delete(z, "AvailableResources") }},
		{"null groups", func(z map[string]any) { z["AvailableResources"] = nil }},
		{"wrong groups", func(z map[string]any) { z["AvailableResources"] = map[string]any{} }},
		{"missing type", func(z map[string]any) { delete(z["AvailableResources"].([]any)[0].(map[string]any), "Type") }},
		{"missing resources", func(z map[string]any) {
			delete(z["AvailableResources"].([]any)[0].(map[string]any), "SupportedResources")
		}},
		{"null resources", func(z map[string]any) {
			z["AvailableResources"].([]any)[0].(map[string]any)["SupportedResources"] = nil
		}},
		{"missing value", func(z map[string]any) {
			delete(z["AvailableResources"].([]any)[0].(map[string]any)["SupportedResources"].([]any)[0].(map[string]any), "Value")
		}},
		{"unknown resource status", func(z map[string]any) {
			z["AvailableResources"].([]any)[0].(map[string]any)["SupportedResources"].([]any)[0].(map[string]any)["Status"] = "Unknown"
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			z := inventoryZone(template.Region, "cn-beijing-a", template.RunInstances.InstanceTypeID, "Available")
			tc.change(z)
			if _, err := inventoryResult(t, template, map[string]any{"AvailableZones": []any{z}}); err == nil {
				t.Fatal("accepted malformed inventory")
			}
		})
	}
	for _, result := range []any{map[string]any{}, map[string]any{"AvailableZones": nil}, map[string]any{"AvailableZones": "not array"}} {
		if _, err := inventoryResult(t, template, result); err == nil {
			t.Fatal("accepted incomplete inventory", result)
		}
	}
}

func TestAvailableZonesEmptyAndInternational(t *testing.T) {
	template := fixture(t)
	result, err := inventoryResult(t, template, map[string]any{"AvailableZones": []any{}})
	if err != nil || result.Zones == nil || len(result.Zones) != 0 {
		t.Fatal(result, err)
	}
	for _, region := range []string{"ap-southeast-1", "ap-southeast-3"} {
		template.Region = region
		template.RunInstances.ZoneID = region + "a"
		result, err = inventoryResult(t, template, map[string]any{"AvailableZones": []any{inventoryZone(region, region+"a", template.RunInstances.InstanceTypeID, "Available")}})
		if err != nil || !reflect.DeepEqual(result.Zones, []string{region + "a"}) {
			t.Fatal(result, err)
		}
	}
}

func refusalEnvelope(code string) string {
	return `{"ResponseMetadata":{"RequestId":"request-1","Action":"RunInstances","Version":"2020-04-01","Service":"ecs","Region":"cn-beijing","Error":{"Code":"` + code + `","Message":"sensitive upstream detail"}}}`
}

func purchaseWithResponse(t *testing.T, body string, status int, transportErr error) (Created, error) {
	t.Helper()
	c := newClient("fixture-id", "fixture-secret")
	count := 0
	c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		count++
		if transportErr != nil {
			return nil, transportErr
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})
	api := callFunc(func(ctx context.Context, service, action, region string, in url.Values, out any) error {
		if action == "RunInstances" {
			return c.call(ctx, service, action, region, in, out)
		}
		result, err := purchaseRead(action)
		if err != nil {
			return err
		}
		data, _ := json.Marshal(result)
		return json.Unmarshal(data, out)
	})
	result, err := create(context.Background(), api, fixture(t), input())
	if count != 1 {
		t.Fatalf("purchase attempted %d times", count)
	}
	return result, err
}

func TestPurchaseCapacityRefusalRequiresDocumentedHTTPEnvelope(t *testing.T) {
	for _, code := range []string{"Insufficient.InstanceCapacity", "Insufficient.VolumePoolCapacity"} {
		for _, suffix := range []string{"", `,"Result":null`, `,"Result": { }`} {
			body := strings.TrimSuffix(refusalEnvelope(code), "}") + suffix + "}"
			result, err := purchaseWithResponse(t, body, http.StatusInternalServerError, nil)
			if err != nil || result.State != "unavailable" || result.InstanceID != "" || result.RequestID != "request-1" {
				t.Fatalf("%+v %v", result, err)
			}
		}
	}
	body := strings.Replace(refusalEnvelope("Insufficient.InstanceCapacity"), `"Code":`, `"CodeN":12345,"Code":`, 1)
	if result, err := purchaseWithResponse(t, body, http.StatusInternalServerError, nil); err != nil || result.State != "unavailable" {
		t.Fatal(result, err)
	}
}

func TestAmbiguousPurchaseNeverAuthorizesFallback(t *testing.T) {
	base := refusalEnvelope("Insufficient.InstanceCapacity")
	tests := []struct {
		name, body string
		status     int
		err        error
	}{
		{"http success plus error", base, 200, nil}, {"wrong error status", base, 400, nil}, {"gateway error", base, 502, nil},
		{"lost response", "", 0, errors.New("sensitive upstream detail")},
		{"internal error", refusalEnvelope("InternalError"), 500, nil},
		{"balance", refusalEnvelope("Insufficient.Balance"), 400, nil},
		{"quota", refusalEnvelope("QuotaExceeded.MaximumInstances"), 400, nil},
		{"permission", refusalEnvelope("AccessDeniedErr"), 403, nil},
		{"invalid zone", refusalEnvelope("InvalidZone.NotFound"), 404, nil},
		{"in progress", refusalEnvelope("IdempotentProcessing"), 412, nil},
		{"malformed", base[:len(base)-1], 500, nil},
		{"missing request ID", strings.Replace(base, `"RequestId":"request-1",`, "", 1), 500, nil},
		{"wrong region", strings.Replace(base, "cn-beijing", "cn-shanghai", 1), 500, nil},
		{"wrong action", strings.Replace(base, "RunInstances", "DescribeInstances", 1), 500, nil},
		{"wrong service", strings.Replace(base, `"Service":"ecs"`, `"Service":"vpc"`, 1), 500, nil},
		{"bad CodeN", strings.Replace(base, `"Code":`, `"CodeN":"123","Code":`, 1), 500, nil},
		{"top-level ID", strings.TrimSuffix(base, "}") + `,"InstanceIds":["i-created"]}`, 500, nil},
		{"nested metadata ID", strings.Replace(base, `"Error":`, `"InstanceIds":["i-created"],"Error":`, 1), 500, nil},
		{"extra error ID", strings.Replace(base, `"Code":`, `"InstanceId":"i-created","Code":`, 1), 500, nil},
		{"duplicate code", strings.Replace(base, `"Code":`, `"Code":"InternalError","Code":`, 1), 500, nil},
		{"duplicate case code", strings.Replace(base, `"Code":`, `"code":"InternalError","Code":`, 1), 500, nil},
		{"duplicate result", strings.TrimSuffix(base, "}") + `,"Result":{"InstanceIds":["i-created"]},"Result":{}}`, 500, nil},
		{"duplicate error", strings.Replace(base, `"Error":`, `"Error":{"Code":"InternalError"},"Error":`, 1), 500, nil},
		{"duplicate envelope", `{"ResponseMetadata":{"Error":{"Code":"InternalError"}},` + base[1:], 500, nil},
		{"oversize", strings.Replace(base, "sensitive upstream detail", strings.Repeat("x", 2<<20), 1), 500, nil},
	}
	for _, value := range []string{`{"InstanceIds":["i-created"]}`, `{"InstanceIds":[]}`, `{"InstanceIds":null}`, `[]`, `true`, `{"Unknown":"payload"}`} {
		tests = append(tests, struct {
			name, body string
			status     int
			err        error
		}{"conflicting Result " + value, strings.TrimSuffix(base, "}") + `,"Result":` + value + `}`, 500, nil})
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r, e := purchaseWithResponse(t, tc.body, tc.status, tc.err)
			if e == nil || r.State == "unavailable" || strings.Contains(e.Error(), "sensitive upstream detail") {
				t.Fatalf("%+v %v", r, e)
			}
		})
	}
}

func TestGenericCapacityErrorsAndPreflightErrorsNeverAuthorizeFallback(t *testing.T) {
	for _, preflight := range []bool{false, true} {
		a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
			if preflight && action == "DescribeImages" {
				return nil, &capacityRejection{"Insufficient.InstanceCapacity", "request-1"}
			}
			if action == "RunInstances" {
				return nil, &apiError{"Insufficient.InstanceCapacity"}
			}
			return purchaseRead(action)
		}}
		result, err := create(context.Background(), a, fixture(t), input())
		if err == nil || result.State == "unavailable" {
			t.Fatal(result, err)
		}
	}
}

func TestZonesActionRoutesReadOnlyAndValidatesTemplate(t *testing.T) {
	a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
		if action != "DescribeAvailableResource" {
			t.Fatal(action)
		}
		return map[string]any{"AvailableZones": []any{}}, nil
	}}
	result, err := execute(context.Background(), a, "volcengine_zones", input())
	if err != nil || len(result.(AvailableZones).Zones) != 0 {
		t.Fatal(result, err)
	}
	in := input()
	in.Template = json.RawMessage(`{"UserData":"forbidden"}`)
	if _, err = execute(context.Background(), a, "volcengine_zones", in); err == nil {
		t.Fatal("accepted template")
	}
	if len(a.calls) != 1 {
		t.Fatal(a.calls)
	}
}

func TestInventoryDuplicateJSONKeysAreAmbiguous(t *testing.T) {
	c := newClient("fixture-id", "fixture-secret")
	c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"ResponseMetadata":{"RequestId":"request-1","Action":"DescribeAvailableResource","Version":"2020-04-01","Service":"ecs","Region":"cn-beijing"},"Result":{"AvailableZones":[],"AvailableZones":[]}}`)), Header: http.Header{}}, nil
	})
	if _, err := availableZones(context.Background(), c, fixture(t)); err == nil {
		t.Fatal("accepted duplicate JSON keys")
	}
}

func TestInventoryBoundsAndErrorsDoNotReturnCandidates(t *testing.T) {
	template := fixture(t)
	zones := make([]any, 101)
	for i := range zones {
		zones[i] = inventoryZone(template.Region, "cn-beijing-a", template.RunInstances.InstanceTypeID, "Available")
	}
	if _, err := inventoryResult(t, template, map[string]any{"AvailableZones": zones}); err == nil {
		t.Fatal("accepted oversized inventory")
	}
	a := callFunc(func(context.Context, string, string, string, url.Values, any) error {
		return errors.New("query unavailable")
	})
	if result, err := availableZones(context.Background(), a, template); err == nil || len(result.Zones) != 0 {
		t.Fatal(result, err)
	}
}

func TestConflictingTypedCapacityResultCannotAuthorizeFallback(t *testing.T) {
	a := callFunc(func(ctx context.Context, service, action, region string, in url.Values, out any) error {
		if action == "RunInstances" {
			if err := json.Unmarshal([]byte(`{"InstanceIds":["i-created"]}`), out); err != nil {
				return err
			}
			return &capacityRejection{"Insufficient.InstanceCapacity", "request-1"}
		}
		result, err := purchaseRead(action)
		if err != nil {
			return err
		}
		data, _ := json.Marshal(result)
		return json.Unmarshal(data, out)
	})
	result, err := create(context.Background(), a, fixture(t), input())
	if err == nil || result.State == "unavailable" {
		t.Fatal(result, err)
	}
}
