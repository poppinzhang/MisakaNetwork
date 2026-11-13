package volcengine

import (
	"context"
	"errors"
	"net/url"
	"testing"
)

func TestImageAcceptsLinuxDistributionsVersionsAndSourcesWithoutQueryFilters(t *testing.T) {
	for _, metadata := range []map[string]any{
		{"Platform": "Ubuntu", "OsName": "Ubuntu 26.04 LTS"},
		{"Platform": "Debian", "OsName": "Debian 13", "Visibility": "private"},
		{"Platform": "Fedora", "OsName": "Fedora 42", "Visibility": "shared"},
		{"Platform": "Other", "OsName": "Custom Linux", "Visibility": "marketplace"},
		{"LifecycleStatus": "Deprecated"},
		{"Snapshots": []map[string]any{{"VolumeKind": "system"}}},
	} {
		api := &fakeAPI{t: t, f: func(action string, query url.Values) (any, error) {
			if action != "DescribeImages" || query.Get("ImageIds.1") != fixture(t).RunInstances.ImageID {
				t.Fatal("image query must use the selected ID")
			}
			for key := range query {
				if key != "ImageIds.1" && key != "MaxResults" && key != "NextToken" {
					t.Fatalf("unexpected image query/filter: %s", key)
				}
			}
			out, _ := purchaseRead(action)
			item := out.(map[string]any)["Images"].([]any)[0].(map[string]any)
			for key, value := range metadata {
				item[key] = value
			}
			return out, nil
		}}
		if err := preflightImage(context.Background(), api, fixture(t)); err != nil {
			t.Fatalf("administrator-selected image rejected: %+v: %v", metadata, err)
		}
	}
}

func TestImageRejectsExtraOrUnknownSnapshotDisks(t *testing.T) {
	for _, snapshots := range [][]map[string]any{
		{{"VolumeKind": "system"}, {"VolumeKind": "data"}},
		{{"VolumeKind": "system"}, {"VolumeKind": "system"}},
		{{"VolumeKind": "unknown"}},
	} {
		api := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
			out, _ := purchaseRead(action)
			out.(map[string]any)["Images"].([]any)[0].(map[string]any)["Snapshots"] = snapshots
			return out, nil
		}}
		if err := preflightImage(context.Background(), api, fixture(t)); err == nil {
			t.Fatalf("unsafe image disks accepted: %+v", snapshots)
		}
	}
}

func TestImageResolvesEachDocumentedVisibilityAfterEmptyDefault(t *testing.T) {
	for _, visibility := range []string{"", "public", "private", "shared", "missing"} {
		t.Run(visibility, func(t *testing.T) {
			calls := 0
			sources := []string{"", "public", "private", "shared"}
			api := &fakeAPI{t: t, f: func(action string, query url.Values) (any, error) {
				if calls >= len(sources) || query.Get("Visibility") != sources[calls] || action != "DescribeImages" || query.Get("ImageIds.1") != fixture(t).RunInstances.ImageID {
					t.Fatalf("unexpected source lookup: %s %v", action, query)
				}
				for key := range query {
					if key != "ImageIds.1" && key != "Visibility" && key != "MaxResults" && key != "NextToken" {
						t.Fatalf("unexpected image filter: %s", key)
					}
				}
				calls++
				if query.Get("Visibility") == visibility {
					return purchaseRead(action)
				}
				if query.Get("Visibility") == "" {
					return map[string]any{"Images": nil, "NextToken": ""}, nil
				}
				return map[string]any{"Images": []any{}, "NextToken": ""}, nil
			}}
			err := preflightImage(context.Background(), api, fixture(t))
			wantCalls := map[string]int{"": 1, "public": 2, "private": 3, "shared": 4, "missing": 4}[visibility]
			if (err != nil) != (visibility == "missing") || calls != wantCalls {
				t.Fatalf("visibility lookup: calls=%d, want=%d, err=%v", calls, wantCalls, err)
			}
		})
	}
}

func TestImageStopsAtFailedOrContradictoryVisibilityLookup(t *testing.T) {
	for _, visibility := range []string{"", "public", "private", "shared"} {
		for _, failure := range []string{"transport", "missing-list", "null-with-next-page", "wrong-id", "duplicate", "windows"} {
			t.Run(visibility+"/"+failure, func(t *testing.T) {
				calls := 0
				wantError := errors.New("image source lookup failed")
				api := &fakeAPI{t: t, f: func(action string, query url.Values) (any, error) {
					calls++
					if query.Get("Visibility") != visibility {
						return map[string]any{"Images": []any{}}, nil
					}
					switch failure {
					case "transport":
						return nil, wantError
					case "missing-list":
						return map[string]any{}, nil
					case "null-with-next-page":
						return map[string]any{"Images": nil, "NextToken": "next"}, nil
					}
					out, _ := purchaseRead(action)
					row := out.(map[string]any)["Images"].([]any)[0].(map[string]any)
					switch failure {
					case "wrong-id":
						row["ImageId"] = "image-other"
					case "duplicate":
						out.(map[string]any)["Images"] = []any{row, row}
					case "windows":
						row["OsType"] = "Windows"
					}
					return out, nil
				}}
				err := preflightImage(context.Background(), api, fixture(t))
				wantCalls := map[string]int{"": 1, "public": 2, "private": 3, "shared": 4}[visibility]
				if err == nil || calls != wantCalls || failure == "transport" && err != wantError {
					t.Fatalf("failed lookup was hidden: calls=%d, want=%d, err=%v", calls, wantCalls, err)
				}
			})
		}
	}
}
