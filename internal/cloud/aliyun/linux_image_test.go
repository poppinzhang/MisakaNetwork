package aliyun

import (
	"context"
	"errors"
	"net/url"
	"testing"
)

func TestImageAcceptsLinuxDistributionsVersionsAndSourcesWithoutQueryFilters(t *testing.T) {
	for _, metadata := range []map[string]any{
		{"Platform": "Ubuntu", "OSName": "Ubuntu 26.04 LTS"},
		{"Platform": "Debian", "OSName": "Debian 13", "ImageOwnerAlias": "self"},
		{"Platform": "Fedora", "OSName": "Fedora 42", "ImageOwnerAlias": "others"},
		{"Platform": "Other", "OSName": "Custom Linux", "ImageOwnerAlias": "marketplace"},
	} {
		api := fixtureAPI(t, nil, func(action string, query url.Values, out map[string]any) error {
			if action != "DescribeImages" || query.Get("ImageId") != fixture().RunInstances.ImageID || query.Get("Status") != "ALL" {
				t.Fatal("image query must use the selected ID and include all states")
			}
			for key := range query {
				if key != "ImageId" && key != "Status" && key != "PageNumber" && key != "PageSize" {
					t.Fatalf("unexpected image query/filter: %s", key)
				}
			}
			item := out["Images"].(map[string]any)["Image"].([]map[string]any)[0]
			for key, value := range metadata {
				item[key] = value
			}
			return nil
		})
		if err := preflightImage(context.Background(), api, fixture()); err != nil {
			t.Fatalf("administrator-selected image rejected: %+v: %v", metadata, err)
		}
	}
}

func TestImageResolvesMarketplaceAndCommunitySourcePartitions(t *testing.T) {
	for _, source := range []string{"marketplace", "community", "missing"} {
		t.Run(source, func(t *testing.T) {
			calls := 0
			api := fixtureAPI(t, nil, func(action string, query url.Values, out map[string]any) error {
				calls++
				if action != "DescribeImages" || query.Get("ImageId") != fixture().RunInstances.ImageID || query.Get("Status") != "ALL" {
					t.Fatal("source lookup changed image ID or state selection")
				}
				owner, public := query.Get("ImageOwnerAlias"), query.Get("IsPublic")
				if calls == 1 && (owner != "" || public != "") || calls == 2 && (owner != "marketplace" || public != "") || calls == 3 && (owner != "others" || public != "true") || calls > 3 {
					t.Fatalf("unexpected source partition query: %v", query)
				}
				found := source == "marketplace" && calls == 2 || source == "community" && calls == 3
				if !found {
					out["TotalCount"] = 0
					out["Images"] = map[string]any{"Image": []any{}}
				} else {
					out["Images"].(map[string]any)["Image"].([]map[string]any)[0]["ImageOwnerAlias"] = owner
				}
				return nil
			})
			err := preflightImage(context.Background(), api, fixture())
			if (err != nil) != (source == "missing") || calls != map[string]int{"marketplace": 2, "community": 3, "missing": 3}[source] {
				t.Fatalf("source resolution: calls=%d err=%v", calls, err)
			}
		})
	}
}

func TestImageDoesNotHideLookupFailureByTryingOtherSources(t *testing.T) {
	calls := 0
	want := errors.New("image lookup failed")
	api := fixtureAPI(t, nil, func(string, url.Values, map[string]any) error {
		calls++
		return want
	})
	if err := preflightImage(context.Background(), api, fixture()); err != want || calls != 1 {
		t.Fatalf("failed source lookup continued: calls=%d err=%v", calls, err)
	}
}

func TestImageRejectsNonLinuxArchitectureStateAndSize(t *testing.T) {
	for _, metadata := range []map[string]any{
		{"OSType": "windows"}, {"OSType": ""}, {"Architecture": "arm64"},
		{"Status": "Creating"}, {"Size": 0}, {"Size": 80}, {"ImageId": "other-image"},
	} {
		api := fixtureAPI(t, nil, func(_ string, _ url.Values, out map[string]any) error {
			item := out["Images"].(map[string]any)["Image"].([]map[string]any)[0]
			for key, value := range metadata {
				item[key] = value
			}
			return nil
		})
		if err := preflightImage(context.Background(), api, fixture()); err == nil {
			t.Fatalf("unusable image accepted: %+v", metadata)
		}
	}
}

func TestCreateSetsNonRootImageOptionOnlyForECSUser(t *testing.T) {
	key := fixtureKey(t)
	for _, username := range []string{"root", "ecs-user", "custom_user"} {
		t.Run(username, func(t *testing.T) {
			template := fixture()
			template.SSHUsername = username
			in := createInput(key)
			in.Template = raw(template)
			purchases := 0
			api := fixtureAPI(t, key, func(action string, query url.Values, _ map[string]any) error {
				if action != "RunInstances" {
					return nil
				}
				purchases++
				want := "false"
				if username == "ecs-user" {
					want = "true"
				}
				if query.Get("ImageOptions.LoginAsNonRoot") != want {
					t.Fatalf("incorrect image login policy for %s", username)
				}
				for _, name := range []string{"UserName", "Username", "UserData", "Password"} {
					if query.Has(name) {
						t.Fatalf("custom username must not generate account/password setup: %s", name)
					}
				}
				return nil
			})
			if _, err := create(context.Background(), api, template, in); err != nil || purchases != 1 {
				t.Fatalf("create: purchases=%d err=%v", purchases, err)
			}
		})
	}
}
