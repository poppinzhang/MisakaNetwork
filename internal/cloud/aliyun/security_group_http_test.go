package aliyun

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"reflect"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestPermissionPriorityEquivalentJSONRepresentations(t *testing.T) {
	for _, input := range []string{`"1"`, `1`, `"50"`, `50`, `"100"`, `100`, `"\u0031"`} {
		t.Run(input, func(t *testing.T) {
			var got permission
			if err := json.Unmarshal([]byte(`{"Priority":`+input+`,"Policy":"Accept","IpProtocol":"TCP"}`), &got); err != nil {
				t.Fatal(err)
			}
			if !matches(`^(?:[1-9][0-9]?|100)$`, got.Priority) || got.Policy != "Accept" || got.IpProtocol != "TCP" {
				t.Fatalf("decoded rule changed: %+v", got)
			}
		})
	}
}

func TestPermissionPriorityRejectsNonIntegerOrOutOfRangeJSON(t *testing.T) {
	for _, input := range []string{`null`, `true`, `false`, `{}`, `[]`, `1.0`, `1e0`, `1E2`, `0`, `-1`, `101`, `1000000000000000000000000000`, `""`, `"0"`, `"-1"`, `"101"`, `"01"`, `"+1"`, `"1.0"`, `"1e0"`, `" 1"`, `"1 "`, `"sensitive-response-value"`} {
		t.Run(input, func(t *testing.T) {
			got := permission{Priority: "50", Policy: "Accept"}
			before := got
			err := json.Unmarshal([]byte(`{"Priority":`+input+`,"Policy":"Drop"}`), &got)
			var malformed *json.UnmarshalTypeError
			if !errors.As(err, &malformed) || malformed.Field != "Priority" || malformed.Value != "invalid priority" {
				t.Fatalf("expected fixed priority diagnostic, got %v", err)
			}
			if got != before {
				t.Fatal("invalid response partially replaced a previously decoded rule")
			}
		})
	}
	var got permission
	if err := json.Unmarshal([]byte(`{"Policy":"Accept"}`), &got); err == nil {
		t.Fatal("missing priority accepted")
	}
	for _, field := range []string{"Policy", "PortRange", "SourceCidrIp", "SecurityGroupRuleId"} {
		if err := json.Unmarshal([]byte(`{"Priority":1,"`+field+`":1}`), &got); err == nil {
			t.Fatalf("numeric %s was coerced", field)
		}
	}
}

// Exercise the production HTTP decoder rather than only the caller mock. The
// synthetic fixture intentionally covers both the documented string priority
// and the equivalent integer encoding; it is not a captured cloud response.
type securityGroupHTTPHarness struct {
	rules          []map[string]any
	priority       json.RawMessage
	calls          map[string]int
	authorizations []url.Values
}

func ruleHTTPFixture(t *testing.T, rule permission, priority json.RawMessage) map[string]any {
	t.Helper()
	payload, err := json.Marshal(rule)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(payload, &out); err != nil {
		t.Fatal(err)
	}
	if priority == nil {
		delete(out, "Priority")
	} else {
		out["Priority"] = priority
	}
	return out
}

func newSecurityGroupHTTPHarness(t *testing.T, key ssh.PublicKey, priority json.RawMessage) (*securityGroupHTTPHarness, *client) {
	t.Helper()
	h := &securityGroupHTTPHarness{priority: priority, calls: map[string]int{}}
	for _, rule := range fixtureRules() {
		h.rules = append(h.rules, ruleHTTPFixture(t, rule, priority))
	}
	base := fixtureAPI(t, key, nil)
	c := newClient("fixture-id", "fixture-secret")
	c.http.Transport = roundTrip(func(request *http.Request) (*http.Response, error) {
		action := request.Header.Get("x-acs-action")
		query := request.URL.Query()
		h.calls[action]++
		out := map[string]any{"RequestId": "security-group-http-fixture"}
		switch action {
		case "DescribeSecurityGroupAttribute":
			if query.Get("SecurityGroupId") != "sg-fixture" || query.Get("Direction") != "all" {
				t.Fatal("security group query did not preserve identity or direction")
			}
			out["SecurityGroupId"] = "sg-fixture"
			out["VpcId"] = "vpc-fixture"
			out["SecurityGroupName"] = groupName
			out["Description"] = groupDescription
			out["InnerAccessPolicy"] = "Accept"
			out["Permissions"] = map[string]any{"Permission": h.rules}
		case "AuthorizeSecurityGroup", "AuthorizeSecurityGroupEgress":
			if query.Get("SecurityGroupId") != "sg-fixture" || query.Get("Permissions.1.Policy") != "accept" || query.Get("Permissions.1.Priority") != "1" || query.Get("Permissions.1.NicType") != "intranet" {
				t.Fatal("rule write changed the fixed security policy")
			}
			h.authorizations = append(h.authorizations, clone(query))
			rule := permission{Direction: "ingress", IpProtocol: query.Get("Permissions.1.IpProtocol"), PortRange: query.Get("Permissions.1.PortRange"), SourceCidrIp: query.Get("Permissions.1.SourceCidrIp"), DestCidrIp: query.Get("Permissions.1.DestCidrIp"), Policy: "Accept", NicType: "intranet", Priority: "1"}
			if action == "AuthorizeSecurityGroupEgress" {
				rule.Direction = "egress"
			}
			h.rules = append(h.rules, ruleHTTPFixture(t, rule, h.priority))
		default:
			service := "ecs"
			if action == "DescribeVpcs" || action == "DescribeVSwitches" {
				service = "vpc"
			}
			if err := base.call(request.Context(), service, action, query.Get("RegionId"), query, &out); err != nil {
				t.Fatal(err)
			}
		}
		payload, err := json.Marshal(out)
		if err != nil {
			t.Fatal(err)
		}
		return retryResponse(http.StatusOK, string(payload)), nil
	})
	return h, c
}

func TestSecurityGroupHTTPReusesCompleteRulesWithBothPriorityEncodings(t *testing.T) {
	key := fixtureKey(t)
	for _, priority := range []string{`"1"`, `1`} {
		t.Run(priority, func(t *testing.T) {
			h, api := newSecurityGroupHTTPHarness(t, key, json.RawMessage(priority))
			input := createInput(key)
			prepared, err := prepare(context.Background(), api, fixture(), input)
			if err != nil || prepared.SecurityGroupID != input.SecurityGroupID || prepared.KeyID != input.KeyID {
				t.Fatalf("prepare: %+v %v", prepared, err)
			}
			if len(h.authorizations) != 0 || h.calls["CreateSecurityGroup"] != 0 || h.calls["ImportKeyPair"] != 0 || h.calls["RunInstances"] != 0 {
				t.Fatalf("ready resources were mutated during preparation: %+v", h.calls)
			}
			created, err := create(context.Background(), api, fixture(), input)
			if err != nil || created.InstanceID != "i-fixture" || h.calls["RunInstances"] != 1 {
				t.Fatalf("create: %+v %v calls=%+v", created, err, h.calls)
			}
		})
	}
}

func TestSecurityGroupHTTPAddsOnlyMissingRuleAndReusesIt(t *testing.T) {
	key := fixtureKey(t)
	for _, priority := range []string{`"1"`, `1`} {
		t.Run(priority, func(t *testing.T) {
			h, api := newSecurityGroupHTTPHarness(t, key, json.RawMessage(priority))
			h.rules = append(h.rules[:1], h.rules[2:]...)
			input := createInput(key)
			for attempt := 0; attempt < 2; attempt++ {
				if _, err := prepare(context.Background(), api, fixture(), input); err != nil {
					t.Fatal(err)
				}
			}
			if len(h.authorizations) != 1 || h.calls["AuthorizeSecurityGroup"] != 1 || h.calls["AuthorizeSecurityGroupEgress"] != 0 || h.calls["RunInstances"] != 0 || h.calls["CreateSecurityGroup"] != 0 || h.calls["ImportKeyPair"] != 0 {
				t.Fatalf("preparation did not reuse existing resources: %+v", h.calls)
			}
			query := h.authorizations[0]
			if query.Get("Permissions.1.PortRange") != "20001/20001" || query.Get("Permissions.1.SourceCidrIp") != "0.0.0.0/0" || query.Get("Permissions.1.IpProtocol") != "tcp" {
				t.Fatal("preparation added a rule other than the missing Sisters ingress")
			}
		})
	}
}

func TestSecurityGroupHTTPInvalidRulesStopBeforeMutationOrPurchase(t *testing.T) {
	key := fixtureKey(t)
	cases := map[string]func(*securityGroupHTTPHarness){
		"missing priority": func(h *securityGroupHTTPHarness) { delete(h.rules[0], "Priority") },
		"drop policy":      func(h *securityGroupHTTPHarness) { h.rules[0]["Policy"] = "Drop" },
		"foreign group":    func(h *securityGroupHTTPHarness) { h.rules[0]["SourceGroupId"] = "sg-external" },
		"all ports":        func(h *securityGroupHTTPHarness) { h.rules[0]["PortRange"] = "1/65535" },
		"duplicate rule":   func(h *securityGroupHTTPHarness) { h.rules = append(h.rules, h.rules[0]) },
	}
	for _, value := range []string{`null`, `true`, `{}`, `[]`, `1.0`, `1e0`, `0`, `-1`, `101`, `"0"`, `"01"`, `"+1"`, `"1.0"`, `"1e0"`, `" 1"`, `"sensitive-response-value"`} {
		cases["priority "+value] = func(h *securityGroupHTTPHarness) { h.rules[0]["Priority"] = json.RawMessage(value) }
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			h, api := newSecurityGroupHTTPHarness(t, key, json.RawMessage(`1`))
			mutate(h)
			before := append([]map[string]any(nil), h.rules...)
			input := createInput(key)
			if _, err := prepare(context.Background(), api, fixture(), input); err == nil {
				t.Fatal("invalid rules passed preparation")
			}
			if _, err := create(context.Background(), api, fixture(), input); err == nil {
				t.Fatal("invalid rules passed pre-purchase verification")
			}
			if len(h.authorizations) != 0 || h.calls["RunInstances"] != 0 || h.calls["CreateSecurityGroup"] != 0 || h.calls["ImportKeyPair"] != 0 || !reflect.DeepEqual(before, h.rules) {
				t.Fatalf("invalid rules caused a mutation or purchase: %+v", h.calls)
			}
		})
	}
}
