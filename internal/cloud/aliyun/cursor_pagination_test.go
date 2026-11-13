package aliyun

import (
	"context"
	"fmt"
	"net/url"
	"testing"
)

// ECS documents TotalCount as meaningless for cursor instance/disk queries.
// These values deliberately disagree with the rows, including across pages.
func TestCursorPaginationIgnoresLegacyCountsAndExhaustsTokens(t *testing.T) {
	for _, action := range []string{"DescribeInstances", "DescribeDisks", "DescribeSecurityGroups"} {
		for _, count := range []any{nil, 0, -1, 9000, "unused", map[string]any{"unused": true}} {
			t.Run(fmt.Sprintf("%s/%v", action, count), func(t *testing.T) {
				calls := 0
				api := fake(func(_ context.Context, _, gotAction, _ string, p url.Values, out any) error {
					calls++
					if gotAction != action || p.Get("MaxResults") != "50" || p.Has("PageSize") || p.Has("PageNumber") || p.Get("Filter") != "kept" {
						t.Fatal("cursor query changed filters or pagination mode")
					}
					v := map[string]any{"RequestId": fmt.Sprintf("request-%d", calls), "TotalCount": count}
					switch calls {
					case 1:
						if p.Has("NextToken") {
							t.Fatal("first query did not start from the first page")
						}
						v["Rows"] = map[string]any{"Row": []any{map[string]any{"id": "first"}}}
						v["NextToken"] = "next-page"
					case 2:
						if p.Get("NextToken") != "next-page" {
							t.Fatal("continuation lost")
						}
						v["TotalCount"] = 42
						v["Rows"] = map[string]any{"Row": []any{map[string]any{"id": "second"}}}
						v["NextToken"] = "last-page"
					case 3:
						if p.Get("NextToken") != "last-page" {
							t.Fatal("last continuation lost")
						}
						v["TotalCount"] = 0
						v["Rows"] = map[string]any{"Row": []any{}}
						v["NextToken"] = ""
					default:
						t.Fatal("continued after cursor exhaustion")
					}
					return put(out, v)
				})
				input := params("Filter", "kept")
				rows, request, err := tokenPages[map[string]any](context.Background(), api, "ecs", "cn-hangzhou", action, "Rows", "Row", input)
				if err != nil || len(rows) != 2 || rows[0]["id"] != "first" || rows[1]["id"] != "second" || calls != 3 || request != "request-3" || len(input) != 1 {
					t.Fatalf("cursor result lost: rows=%v request=%s calls=%d err=%v", rows, request, calls, err)
				}
			})
		}
	}
}

func TestCursorPaginationLimitsActualRowsWithoutUsingTotalCount(t *testing.T) {
	for _, mode := range []string{"oversized page", "too many rows", "broken continuation", "null list", "missing list", "null row"} {
		t.Run(mode, func(t *testing.T) {
			calls := 0
			api := fake(func(_ context.Context, _, _, _ string, _ url.Values, out any) error {
				calls++
				rows := []any{}
				for i := 0; i < 50; i++ {
					rows = append(rows, map[string]any{"id": fmt.Sprintf("row-%d-%d", calls, i)})
				}
				v := map[string]any{"TotalCount": 0, "NextToken": fmt.Sprintf("next-%d", calls), "Rows": map[string]any{"Row": rows}}
				switch mode {
				case "oversized page":
					v["Rows"] = map[string]any{"Row": append(rows, map[string]any{"id": "overflow"})}
				case "broken continuation":
					v["NextToken"] = 5
				case "null list":
					v["Rows"] = map[string]any{"Row": nil}
				case "missing list":
					delete(v, "Rows")
				case "null row":
					v["Rows"] = map[string]any{"Row": []any{nil}}
				}
				return put(out, v)
			})
			rows, _, err := tokenPages[map[string]any](context.Background(), api, "ecs", "cn-hangzhou", "DescribeInstances", "Rows", "Row", nil)
			if err == nil || rows != nil || calls > 82 || mode != "too many rows" && calls != 1 {
				t.Fatalf("invalid cursor result accepted: calls=%d rows=%d err=%v", calls, len(rows), err)
			}
		})
	}
}

func TestPageNumberPaginationStillRequiresAccurateCount(t *testing.T) {
	for _, count := range []any{0, -1, "1", nil} {
		api := fake(func(_ context.Context, _, _, _ string, p url.Values, out any) error {
			v := page(p, "Rows", "Row", []any{map[string]any{"id": "present"}}, 1)
			v["TotalCount"] = count
			return put(out, v)
		})
		if _, _, err := pages[map[string]any](context.Background(), api, "ecs", "cn-hangzhou", "DescribeImages", "Rows", "Row", nil); err == nil {
			t.Fatalf("invalid page-number count accepted: %v", count)
		}
	}
}
