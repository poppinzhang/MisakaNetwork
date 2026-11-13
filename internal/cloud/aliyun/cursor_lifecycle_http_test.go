package aliyun

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

type cursorLifecycleRequest struct {
	action string
	query  url.Values
}

// These synthetic HTTP responses reproduce the documented cursor contract:
// TotalCount is not authoritative even when the returned rows are nonempty.
func cursorLifecyclePage(container, item string, rows any, next string) map[string]any {
	return map[string]any{
		"RequestId": "cursor-lifecycle-request", "TotalCount": 0,
		"NextToken": next, container: map[string]any{item: rows},
	}
}

func cursorLifecycleInput() Input {
	return Input{Region: "cn-hangzhou", InstanceID: "i-fixture", ClientToken: "operation-token-123"}
}

func cursorLifecycleDisk(id, kind string) map[string]any {
	return map[string]any{
		"DiskId": id, "InstanceId": "i-fixture", "Type": kind,
		"Status": "In_use", "DeleteWithInstance": true,
	}
}

func newCursorLifecycleHTTPClient(t *testing.T, respond func(string, url.Values) (int, map[string]any)) (*client, *[]cursorLifecycleRequest) {
	t.Helper()
	requests := []cursorLifecycleRequest{}
	c := newClient("fixture-id", "fixture-secret")
	c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		action := r.Header.Get("x-acs-action")
		query := r.URL.Query()
		requests = append(requests, cursorLifecycleRequest{action: action, query: clone(query)})
		if r.URL.Host != "ecs.cn-hangzhou.aliyuncs.com" || r.Method != http.MethodPost || query.Get("RegionId") != "cn-hangzhou" {
			t.Fatal("lifecycle query changed its authenticated endpoint or region")
		}
		if strings.HasPrefix(action, "Describe") && (query.Get("MaxResults") != "50" || query.Has("PageNumber") || query.Has("PageSize")) {
			t.Fatal("lifecycle lookup did not use cursor pagination")
		}
		status, out := respond(action, query)
		body, err := json.Marshal(out)
		if err != nil {
			t.Fatal(err)
		}
		return retryResponse(status, string(body)), nil
	})
	return c, &requests
}

func requireCursorLifecycleInstanceFilter(t *testing.T, p url.Values, recover bool) {
	t.Helper()
	if recover {
		if p.Has("InstanceIds") || p.Get("Tag.1.Key") != managedTag || p.Get("Tag.1.Value") != managedValue || p.Get("Tag.2.Key") != operationTag || p.Get("Tag.2.Value") != "operation-token-123" {
			t.Fatal("recovery failed to filter by both exact ownership tags")
		}
		return
	}
	if p.Get("InstanceIds") != `["i-fixture"]` || p.Has("Tag.1.Key") || p.Has("Tag.2.Key") {
		t.Fatal("known-instance lookup changed its exact instance ID filter")
	}
}

func requireCursorLifecycleReadOnly(t *testing.T, requests []cursorLifecycleRequest) {
	t.Helper()
	for _, request := range requests {
		if request.action != "DescribeInstances" && request.action != "DescribeDisks" {
			t.Fatalf("incomplete or unsafe lookup performed %s", request.action)
		}
	}
}

func TestCursorLifecycleHTTPDescribeAndRecoverIgnoreZeroCount(t *testing.T) {
	for _, recover := range []bool{false, true} {
		name := "known instance"
		if recover {
			name = "recover by operation tags"
		}
		t.Run(name, func(t *testing.T) {
			input := cursorLifecycleInput()
			if recover {
				input.InstanceID = ""
			}
			pages := 0
			api, requests := newCursorLifecycleHTTPClient(t, func(action string, p url.Values) (int, map[string]any) {
				if action != "DescribeInstances" {
					t.Fatalf("query attempted %s", action)
				}
				requireCursorLifecycleInstanceFilter(t, p, recover)
				pages++
				if pages == 1 {
					if p.Has("NextToken") {
						t.Fatal("first page unexpectedly carried a cursor")
					}
					return http.StatusOK, cursorLifecyclePage("Instances", "Instance", []any{fixtureInstance()}, "after-instance")
				}
				if pages != 2 || p.Get("NextToken") != "after-instance" {
					t.Fatal("query did not exhaust the exact continuation token")
				}
				return http.StatusOK, cursorLifecyclePage("Instances", "Instance", []any{}, "")
			})
			got, err := describe(context.Background(), api, input, recover)
			if err != nil || !got.Exists || got.InstanceID != "i-fixture" || got.State != "RUNNING" || got.PublicIP != "203.0.113.1" || pages != 2 {
				t.Fatalf("existing instance was not recovered: %+v, %v, pages=%d", got, err, pages)
			}
			requireCursorLifecycleReadOnly(t, *requests)
		})
	}
}

func TestCursorLifecycleHTTPReleaseWaitsForExplicitAbsence(t *testing.T) {
	input := cursorLifecycleInput()
	absent := false
	deletes := 0
	api, requests := newCursorLifecycleHTTPClient(t, func(action string, p url.Values) (int, map[string]any) {
		switch action {
		case "DescribeInstances":
			requireCursorLifecycleInstanceFilter(t, p, false)
			rows := []any{}
			if !absent {
				instance := fixtureInstance()
				instance["NetworkInterfaces"] = map[string]any{"NetworkInterface": []any{map[string]any{"NetworkInterfaceId": "eni-primary", "Type": "Primary"}}}
				rows = append(rows, instance)
			}
			return http.StatusOK, cursorLifecyclePage("Instances", "Instance", rows, "")
		case "DescribeDisks":
			if p.Get("InstanceId") != input.InstanceID || p.Has("DiskType") {
				t.Fatal("release must inspect every disk attached to the exact instance")
			}
			return http.StatusOK, cursorLifecyclePage("Disks", "Disk", []any{cursorLifecycleDisk("d-system", "system")}, "")
		case "DeleteInstance":
			deletes++
			if p.Get("InstanceId") != input.InstanceID || p.Get("Force") != "true" || p.Get("ForceStop") != "false" {
				t.Fatal("release changed the exact instance or shutdown policy")
			}
			return http.StatusOK, map[string]any{"RequestId": "cursor-delete-accepted"}
		default:
			t.Fatalf("lifecycle attempted unexpected action %s", action)
			return 0, nil
		}
	})
	result, err := release(context.Background(), api, input)
	if err != nil || result.RequestID != "cursor-delete-accepted" || deletes != 1 {
		t.Fatalf("release with zero cursor counts failed: %+v %v, deletes=%d", result, err, deletes)
	}
	stillRunning, err := describe(context.Background(), api, input, false)
	if err != nil || !stillRunning.Exists || stillRunning.State != "RUNNING" {
		t.Fatalf("accepted deletion or zero count incorrectly proved absence: %+v %v", stillRunning, err)
	}
	absent = true
	removed, err := describe(context.Background(), api, input, false)
	if err != nil || removed.Exists || removed.InstanceID != input.InstanceID || removed.RequestID == "" {
		t.Fatalf("explicit terminal empty list did not confirm absence: %+v %v", removed, err)
	}
	if deletes != 1 {
		t.Fatal("release confirmation replayed the deletion")
	}
	for _, request := range *requests {
		if request.action == "RunInstances" {
			t.Fatal("lifecycle confirmation purchased another instance")
		}
	}
}

func TestCursorLifecycleHTTPSecondPageDataDiskBlocksRelease(t *testing.T) {
	pages := 0
	api, requests := newCursorLifecycleHTTPClient(t, func(action string, p url.Values) (int, map[string]any) {
		switch action {
		case "DescribeInstances":
			requireCursorLifecycleInstanceFilter(t, p, false)
			return http.StatusOK, cursorLifecyclePage("Instances", "Instance", []any{fixtureInstance()}, "")
		case "DescribeDisks":
			pages++
			if p.Get("InstanceId") != "i-fixture" || p.Has("DiskType") {
				t.Fatal("disk query could hide an external attached disk")
			}
			if pages == 1 {
				return http.StatusOK, cursorLifecyclePage("Disks", "Disk", []any{cursorLifecycleDisk("d-system", "system")}, "extra-disk")
			}
			if pages != 2 || p.Get("NextToken") != "extra-disk" {
				t.Fatal("release failed to follow the disk continuation")
			}
			return http.StatusOK, cursorLifecyclePage("Disks", "Disk", []any{cursorLifecycleDisk("d-external", "data")}, "")
		default:
			t.Fatalf("external disk did not block %s", action)
			return 0, nil
		}
	})
	if _, err := release(context.Background(), api, cursorLifecycleInput()); err == nil || !strings.Contains(err.Error(), "单系统盘配置") || pages != 2 {
		t.Fatalf("second-page external disk did not block release: %v, pages=%d", err, pages)
	}
	requireCursorLifecycleReadOnly(t, *requests)
}

func cursorLifecycleBrokenPage(kind, container, item string, secondRow any) (int, map[string]any) {
	switch kind {
	case "HTTP failure":
		return http.StatusServiceUnavailable, map[string]any{"RequestId": "cursor-page-failed", "Code": "ServiceUnavailable", "Message": "sensitive-response-value"}
	case "invalid list":
		return http.StatusOK, cursorLifecyclePage(container, item, nil, "")
	default:
		return http.StatusOK, cursorLifecyclePage(container, item, []any{secondRow}, "continuation")
	}
}

func TestCursorLifecycleHTTPIncompleteInstancePagesNeverConfirmAbsence(t *testing.T) {
	for _, kind := range []string{"HTTP failure", "invalid list", "repeated token"} {
		for _, operation := range []string{"describe", "recover", "release"} {
			t.Run(kind+"/"+operation, func(t *testing.T) {
				pages := 0
				api, requests := newCursorLifecycleHTTPClient(t, func(action string, p url.Values) (int, map[string]any) {
					if action != "DescribeInstances" {
						t.Fatalf("incomplete instance traversal allowed %s", action)
					}
					requireCursorLifecycleInstanceFilter(t, p, operation == "recover")
					pages++
					if pages == 1 {
						return http.StatusOK, cursorLifecyclePage("Instances", "Instance", []any{fixtureInstance()}, "continuation")
					}
					if pages != 2 || p.Get("NextToken") != "continuation" {
						t.Fatal("incomplete traversal replayed or changed its continuation")
					}
					second := fixtureInstance()
					second["InstanceId"] = "i-second"
					return cursorLifecycleBrokenPage(kind, "Instances", "Instance", second)
				})
				input := cursorLifecycleInput()
				var err error
				if operation == "release" {
					_, err = release(context.Background(), api, input)
				} else {
					if operation == "recover" {
						input.InstanceID = ""
					}
					_, err = describe(context.Background(), api, input, operation == "recover")
				}
				if err == nil || pages != 2 || strings.Contains(err.Error(), "sensitive-response-value") {
					t.Fatalf("incomplete pages became an authoritative result: %v, pages=%d", err, pages)
				}
				requireCursorLifecycleReadOnly(t, *requests)
			})
		}
	}
}

func TestCursorLifecycleHTTPIncompleteDiskPagesNeverDelete(t *testing.T) {
	for _, kind := range []string{"HTTP failure", "invalid list", "repeated token"} {
		t.Run(kind, func(t *testing.T) {
			pages := 0
			api, requests := newCursorLifecycleHTTPClient(t, func(action string, p url.Values) (int, map[string]any) {
				switch action {
				case "DescribeInstances":
					requireCursorLifecycleInstanceFilter(t, p, false)
					return http.StatusOK, cursorLifecyclePage("Instances", "Instance", []any{fixtureInstance()}, "")
				case "DescribeDisks":
					if p.Get("InstanceId") != "i-fixture" || p.Has("DiskType") {
						t.Fatal("release did not inspect all attached disks")
					}
					pages++
					if pages == 1 {
						return http.StatusOK, cursorLifecyclePage("Disks", "Disk", []any{cursorLifecycleDisk("d-system", "system")}, "continuation")
					}
					if pages != 2 || p.Get("NextToken") != "continuation" {
						t.Fatal("incomplete disk traversal replayed or changed its continuation")
					}
					return cursorLifecycleBrokenPage(kind, "Disks", "Disk", cursorLifecycleDisk("d-second", "system"))
				default:
					t.Fatalf("incomplete disk traversal allowed %s", action)
					return 0, nil
				}
			})
			if _, err := release(context.Background(), api, cursorLifecycleInput()); err == nil || pages != 2 || strings.Contains(err.Error(), "sensitive-response-value") {
				t.Fatalf("incomplete disk pages allowed deletion: %v, pages=%d", err, pages)
			}
			requireCursorLifecycleReadOnly(t, *requests)
		})
	}
}

func TestCursorLifecycleHTTPStillRejectsWrongInstanceOwnership(t *testing.T) {
	for _, kind := range []string{"instance ID", "management tag", "operation tag"} {
		for _, recover := range []bool{false, true} {
			if kind == "instance ID" && recover {
				continue // Recovery intentionally learns the instance ID from its tags.
			}
			t.Run(kind+"/recover="+map[bool]string{false: "false", true: "true"}[recover], func(t *testing.T) {
				api, requests := newCursorLifecycleHTTPClient(t, func(action string, p url.Values) (int, map[string]any) {
					if action != "DescribeInstances" {
						t.Fatalf("unowned response allowed %s", action)
					}
					requireCursorLifecycleInstanceFilter(t, p, recover)
					row := fixtureInstance()
					if kind == "instance ID" {
						row["InstanceId"] = "i-unrelated"
					} else {
						tags := row["Tags"].(map[string]any)["Tag"].([]map[string]string)
						index := 0
						if kind == "operation tag" {
							index = 1
						}
						tags[index]["TagValue"] = "different-owner"
					}
					return http.StatusOK, cursorLifecyclePage("Instances", "Instance", []any{row}, "")
				})
				if _, err := describe(context.Background(), api, cursorLifecycleInput(), recover); err == nil {
					t.Fatal("irrelevant TotalCount bypassed instance ownership validation")
				}
				requireCursorLifecycleReadOnly(t, *requests)
			})
		}
	}
}
