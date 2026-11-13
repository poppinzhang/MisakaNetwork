package aliyun

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func assertResponseReason(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || err.Error() != want {
		t.Fatalf("response category = %v, want %q", err, want)
	}
	if !strings.Contains(err.Error(), "操作结果可能未知") {
		t.Fatal("response failure lost unknown-result semantics")
	}
	for _, private := range []string{"sensitive-secret", "https://", "192.0.2.1", "SecretKey", "json:", "cannot unmarshal"} {
		if strings.Contains(err.Error(), private) {
			t.Fatalf("response diagnostic contains %q", private)
		}
	}
}

func TestResponseFieldDiagnosticsUseOnlyExactSecurityGroupFields(t *testing.T) {
	for field, want := range map[string]string{
		"Priority": groupPriorityTypeReason, "Permissions.Permission.Priority": groupPriorityTypeReason,
		"Permissions": groupRuleListTypeReason, "Permissions.Permission": groupRuleListTypeReason,
		"NextToken": groupPageTokenTypeReason, "SecurityGroupId": groupOwnershipTypeReason,
		"VpcId": groupOwnershipTypeReason, "SecurityGroupName": groupOwnershipTypeReason,
		"Description": groupOwnershipTypeReason, "InnerAccessPolicy": groupOwnershipTypeReason,
		"Policy": groupRuleTypeReason, "Permissions.Permission.Policy": groupRuleTypeReason,
		"fields.Policy": groupRuleTypeReason, "Permissions.Permission.fields.Policy": groupRuleTypeReason,
		"SourceCidrIp": groupRuleTypeReason, "Permissions.Permission.SecurityGroupRuleId": groupRuleTypeReason,
		"sensitive-secret.Priority":                        groupResponseFieldReason,
		"Permissions.Permission.Priority.sensitive-secret": groupResponseFieldReason,
		"permissions.permission.priority":                  groupResponseFieldReason,
		"sensitive-secret":                                 groupResponseFieldReason, "": groupResponseFieldReason,
	} {
		t.Run(field, func(t *testing.T) {
			cause := &json.UnmarshalTypeError{
				Value: "sensitive-secret https://192.0.2.1/?SecretKey=sensitive-secret",
				Type:  reflect.TypeFor[string](), Struct: "sensitive-secret", Field: field,
			}
			for _, wrapped := range []error{cause, fmt.Errorf("sensitive-secret: %w", cause)} {
				assertResponseReason(t, responseError("DescribeSecurityGroupAttribute", responseFieldType, wrapped), want)
				for _, action := range []string{"DescribeSecurityGroups", "CreateSecurityGroup", "DescribeImages", "sensitive-secret", "DescribeSecurityGroupAttribute.sensitive-secret"} {
					assertResponseReason(t, responseError(action, responseFieldType, wrapped), responseFieldReason)
				}
			}
		})
	}
	for _, cause := range []error{nil, errors.New("json: cannot unmarshal sensitive-secret into Priority")} {
		assertResponseReason(t, responseError("DescribeSecurityGroupAttribute", responseFieldType, cause), groupResponseFieldReason)
	}
}

func TestResponseReasonsCrossPreparationBoundaryOnlyAsExactFixedMessages(t *testing.T) {
	for reason := range safeResponseReasons {
		if got := preparationError("安全组准备", errors.New(reason)); got.Error() != "安全组准备："+reason {
			t.Fatalf("fixed response category was lost: %v", got)
		}
		for _, unsafe := range []string{"sensitive-secret " + reason, reason + " sensitive-secret", reason + ": https://192.0.2.1/"} {
			if got := preparationError("安全组准备", errors.New(unsafe)); got.Error() != "安全组准备：云资源准备未完成，请重试查询确认" {
				t.Fatalf("untrusted response category escaped: %v", got)
			}
		}
	}
}

type failedResponseReader struct{ closed bool }

func (*failedResponseReader) Read(b []byte) (int, error) {
	return copy(b, `{"Message":"sensitive-secret"`), errors.New("sensitive-secret https://192.0.2.1/?SecretKey=sensitive-secret")
}
func (r *failedResponseReader) Close() error { r.closed = true; return nil }

func TestResponseReadSizeAndStatusFailuresAreDistinctAndNeverRetried(t *testing.T) {
	for _, action := range []string{"DescribeSecurityGroupAttribute", "DescribeImages", "CreateSecurityGroup", "RunInstances"} {
		for _, kind := range []responseFailureKind{responseReadFailure, responseTooLarge, responseHTTPStatus} {
			t.Run(fmt.Sprintf("%s/%d", action, kind), func(t *testing.T) {
				c := newClient("fixture-id", "fixture-secret")
				calls := 0
				broken := &failedResponseReader{}
				c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
					calls++
					switch kind {
					case responseReadFailure:
						return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: broken}, nil
					case responseTooLarge:
						return retryResponse(http.StatusOK, strings.Repeat("x", (2<<20)+1)), nil
					default:
						return retryResponse(http.StatusBadGateway, `{"RequestId":"fixture-request","Message":"sensitive-secret"}`), nil
					}
				})
				var out any
				err := c.call(context.Background(), "ecs", action, "cn-hangzhou", nil, &out)
				want := map[responseFailureKind]string{responseReadFailure: responseReadReason, responseTooLarge: responseTooLargeReason, responseHTTPStatus: responseHTTPReason}[kind]
				if action == "DescribeSecurityGroupAttribute" {
					want = map[responseFailureKind]string{responseReadFailure: groupResponseReadReason, responseTooLarge: groupResponseSizeReason, responseHTTPStatus: groupResponseHTTPReason}[kind]
				}
				assertResponseReason(t, err, want)
				if calls != 1 || kind == responseReadFailure && !broken.closed {
					t.Fatalf("response failure retried or leaked body: calls=%d closed=%v", calls, broken.closed)
				}
			})
		}
	}
}

func securityGroupResponseFixture() map[string]any {
	return map[string]any{
		"RequestId": "fixture-request", "SecurityGroupId": "sg-fixture", "VpcId": "vpc-fixture",
		"SecurityGroupName": groupName, "Description": groupDescription, "InnerAccessPolicy": "Accept",
		"Permissions": map[string]any{"Permission": []any{map[string]any{"Priority": "1", "Policy": "Accept"}}},
	}
}

func TestSecurityGroupSchemaFailureClassifiesActualDecodeAndStopsRead(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(map[string]any)
		want   string
	}{
		{"priority", func(out map[string]any) {
			out["Permissions"].(map[string]any)["Permission"].([]any)[0].(map[string]any)["Priority"] = true
		}, groupPriorityTypeReason},
		{"rules container", func(out map[string]any) { out["Permissions"] = "sensitive-secret" }, groupRuleListTypeReason},
		{"rules list", func(out map[string]any) { out["Permissions"] = map[string]any{"Permission": "sensitive-secret"} }, groupRuleListTypeReason},
		{"pagination", func(out map[string]any) { out["NextToken"] = map[string]any{"SecretKey": "sensitive-secret"} }, groupPageTokenTypeReason},
		{"group ID", func(out map[string]any) { out["SecurityGroupId"] = []string{"sensitive-secret"} }, groupOwnershipTypeReason},
		{"VPC ID", func(out map[string]any) { out["VpcId"] = []string{"sensitive-secret"} }, groupOwnershipTypeReason},
		{"rule content", func(out map[string]any) {
			out["Permissions"].(map[string]any)["Permission"].([]any)[0].(map[string]any)["Policy"] = []string{"sensitive-secret"}
		}, groupRuleTypeReason},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Header.Get("x-acs-action") != "DescribeSecurityGroupAttribute" {
					t.Fatal("malformed security group response allowed a different action")
				}
				out := securityGroupResponseFixture()
				tc.mutate(out)
				body, _ := json.Marshal(out)
				return retryResponse(http.StatusOK, string(body)), nil
			})
			_, err := readRules(context.Background(), c, fixture(), "vpc-fixture", "sg-fixture")
			assertResponseReason(t, err, tc.want)
			if calls != 1 {
				t.Fatalf("schema failure retried: calls=%d", calls)
			}
		})
	}
}

func TestOtherResponseSchemaFailuresRemainGenericAndDoNotReplayWrites(t *testing.T) {
	for _, action := range []string{"DescribeImages", "CreateSecurityGroup", "RunInstances"} {
		c := newClient("fixture-id", "fixture-secret")
		calls := 0
		c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
			calls++
			return retryResponse(http.StatusOK, `{"RequestId":"fixture-request","Priority":{"SecretKey":"sensitive-secret"}}`), nil
		})
		var out struct{ Priority string }
		err := c.call(context.Background(), "ecs", action, "cn-hangzhou", nil, &out)
		assertResponseReason(t, err, responseFieldReason)
		if calls != 1 {
			t.Fatalf("schema failure replayed %s %d times", action, calls)
		}
	}
}

func TestResponseDiagnosticsPreserveAuthoritativeAPIAndAmbiguousRejectionRules(t *testing.T) {
	for _, tc := range []struct {
		status int
		body   string
		api    bool
	}{
		{400, `{"RequestId":"fixture-request","Code":"InvalidParameter","Message":"sensitive-secret"}`, true},
		{500, `{"RequestId":"fixture-request","Code":"InvalidParameter","Message":"sensitive-secret"}`, false},
		{400, `{"RequestId":"fixture-request","Code":"InvalidParameter","SecurityGroupId":"sg-fixture","Message":"sensitive-secret"}`, false},
	} {
		c := newClient("fixture-id", "fixture-secret")
		calls := 0
		c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
			calls++
			return retryResponse(tc.status, tc.body), nil
		})
		var out any
		err := c.call(context.Background(), "ecs", "CreateSecurityGroup", "cn-hangzhou", nil, &out)
		var api *apiError
		if err == nil || errors.As(err, &api) != tc.api || calls != 1 || strings.Contains(err.Error(), "sensitive-secret") {
			t.Fatalf("response diagnostic changed rejection semantics: err=%v calls=%d", err, calls)
		}
	}
}

var _ io.ReadCloser = (*failedResponseReader)(nil)
