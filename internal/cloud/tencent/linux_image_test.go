package tencent

import (
	"context"
	"testing"
)

func TestImageAcceptsLinuxDistributionsVersionsAndSourcesWithoutQueryFilters(t *testing.T) {
	for _, metadata := range []map[string]any{
		{"Platform": "Ubuntu", "OsName": "Ubuntu Server 26.04 LTS"},
		{"Platform": "Debian", "OsName": "Debian 13", "ImageType": "PRIVATE_IMAGE"},
		{"Platform": "Fedora", "OsName": "Fedora 42", "ImageType": "SHARED_IMAGE"},
		{"Platform": "TencentOS", "OsName": "TencentOS Server 4", "ImageType": "MARKET_IMAGE"},
		{"Platform": "Other", "OsName": "Custom Linux release"},
		{"Platform": "", "OsName": "Administrator custom image"},
		{"SnapshotSet": []map[string]any{{"DiskUsage": "SYSTEM_DISK"}}},
	} {
		api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
			if c.action != "DescribeImages" || len(c.body) != 1 {
				t.Fatalf("unexpected image query/filter: %+v", c)
			}
			ids, ok := c.body["ImageIds"].([]any)
			if !ok || len(ids) != 1 || ids[0] != fixtureTemplate().RunInstances.ImageID {
				t.Fatal("image query must use the selected ID")
			}
			out := imageResponse()
			item := out["ImageSet"].([]any)[0].(map[string]any)
			for key, value := range metadata {
				item[key] = value
			}
			return out, nil
		}}
		if err := preflightImage(context.Background(), api, fixtureTemplate()); err != nil {
			t.Fatalf("administrator-selected image rejected: %+v: %v", metadata, err)
		}
	}
}

func TestImageRejectsExtraOrUnknownSnapshotDisks(t *testing.T) {
	for _, snapshots := range [][]map[string]any{
		{{"DiskUsage": "SYSTEM_DISK"}, {"DiskUsage": "DATA_DISK"}},
		{{"DiskUsage": "SYSTEM_DISK"}, {"DiskUsage": "SYSTEM_DISK"}},
		{{"DiskUsage": "unknown"}},
	} {
		api := &fakeAPI{t: t, respond: func(callRecord) (any, error) {
			out := imageResponse()
			out["ImageSet"].([]any)[0].(map[string]any)["SnapshotSet"] = snapshots
			return out, nil
		}}
		if err := preflightImage(context.Background(), api, fixtureTemplate()); err == nil {
			t.Fatalf("unsafe image disks accepted: %+v", snapshots)
		}
	}
}
