package aliyun

import (
	"context"
	"net/url"
	"testing"
)

func TestImageMappingTypeRequiresExplicitSystemExceptForOfficialImages(t *testing.T) {
	for _, owner := range []string{"system", "self", "others", "marketplace", "", "unknown"} {
		for _, diskType := range []string{"omitted", "", "system", "data", "unknown", "System"} {
			t.Run(owner+"/"+diskType, func(t *testing.T) {
				api := fixtureAPI(t, nil, func(action string, _ url.Values, out map[string]any) error {
					if action != "DescribeImages" {
						t.Fatalf("unexpected action: %s", action)
					}
					item := out["Images"].(map[string]any)["Image"].([]map[string]any)[0]
					item["ImageOwnerAlias"] = owner
					mapping := map[string]any{"Size": "20"}
					if diskType != "omitted" {
						mapping["Type"] = diskType
					}
					item["DiskDeviceMappings"] = map[string]any{"DiskDeviceMapping": []any{mapping}}
					return nil
				})
				err := preflightImage(context.Background(), api, fixture())
				wantOK := diskType == "system" || owner == "system" && (diskType == "omitted" || diskType == "")
				if (err == nil) != wantOK {
					t.Fatalf("owner=%q type=%q: err=%v, want success=%v", owner, diskType, err, wantOK)
				}
				if !wantOK {
					want := "模板镜像磁盘类型无法确认，已停止创建"
					if diskType == "data" {
						want = "模板镜像必须仅包含一块系统盘，不允许附带数据盘"
					}
					if err.Error() != want {
						t.Fatalf("got %q, want %q", err, want)
					}
				}
			})
		}
	}
}

func TestOfficialImageWithoutMappingTypePreparesAndCreates(t *testing.T) {
	key := fixtureKey(t)
	input := createInput(key)
	for _, diskType := range []string{"omitted", ""} {
		t.Run(diskType, func(t *testing.T) {
			imageChecks, purchases := 0, 0
			api := fixtureAPI(t, key, func(action string, query url.Values, out map[string]any) error {
				switch action {
				case "DescribeImages":
					imageChecks++
					mapping := map[string]any{"Device": "/dev/xvda", "Size": "20", "SnapshotId": ""}
					if diskType != "omitted" {
						mapping["Type"] = diskType
					}
					out["Images"].(map[string]any)["Image"].([]map[string]any)[0]["DiskDeviceMappings"] = map[string]any{"DiskDeviceMapping": []any{mapping}}
				case "RunInstances":
					purchases++
					if query.Get("SystemDisk.Size") != "40" || query.Has("DataDisk.1.Size") || query.Get("Amount") != "1" {
						t.Fatal("public image compatibility changed the single-instance, single-disk purchase")
					}
				}
				return nil
			})
			prepared, err := prepare(context.Background(), api, fixture(), input)
			if err != nil || prepared.KeyID != input.KeyID || prepared.SecurityGroupID != input.SecurityGroupID || purchases != 0 {
				t.Fatalf("prepare: %+v, err=%v, purchases=%d", prepared, err, purchases)
			}
			created, err := create(context.Background(), api, fixture(), input)
			if err != nil || created.InstanceID != "i-fixture" || purchases != 1 || imageChecks != 2 {
				t.Fatalf("create: %+v, err=%v, purchases=%d, image checks=%d", created, err, purchases, imageChecks)
			}
		})
	}
}

func TestImageMappingFailuresStopPreparationAndPurchaseBeforeWrites(t *testing.T) {
	const missingMapping = "模板镜像缺少磁盘映射信息，无法确认单系统盘配置"
	const multipleDisks = "模板镜像必须仅包含一块系统盘，不允许附带数据盘"
	const unknownType = "模板镜像磁盘类型无法确认，已停止创建"
	const invalidSize = "模板镜像系统盘映射与容量不匹配"
	tests := []struct {
		name   string
		mutate func(map[string]any)
		want   string
	}{
		{"nonpublic mapping omitted", func(i map[string]any) { i["ImageOwnerAlias"] = "self"; delete(i, "DiskDeviceMappings") }, missingMapping},
		{"nonpublic mapping null", func(i map[string]any) { i["ImageOwnerAlias"] = "self"; i["DiskDeviceMappings"] = nil }, missingMapping},
		{"nonpublic list omitted", func(i map[string]any) { i["ImageOwnerAlias"] = "self"; i["DiskDeviceMappings"] = map[string]any{} }, missingMapping},
		{"nonpublic list null", func(i map[string]any) {
			i["ImageOwnerAlias"] = "self"
			i["DiskDeviceMappings"] = map[string]any{"DiskDeviceMapping": nil}
		}, missingMapping},
		{"nonpublic list empty", func(i map[string]any) {
			i["ImageOwnerAlias"] = "self"
			i["DiskDeviceMappings"] = map[string]any{"DiskDeviceMapping": []any{}}
		}, missingMapping},
		{"extra data disk", func(i map[string]any) {
			i["DiskDeviceMappings"] = map[string]any{"DiskDeviceMapping": []any{map[string]any{"Size": "20"}, map[string]any{"Type": "data", "Size": "100"}}}
		}, multipleDisks},
		{"two system disks", func(i map[string]any) {
			i["DiskDeviceMappings"] = map[string]any{"DiskDeviceMapping": []any{map[string]any{"Type": "system", "Size": "20"}, map[string]any{"Type": "system", "Size": "20"}}}
		}, multipleDisks},
		{"explicit data disk", func(i map[string]any) { imageMappingForTest(i)["Type"] = "data" }, multipleDisks},
		{"unknown type", func(i map[string]any) { imageMappingForTest(i)["Type"] = "unknown" }, unknownType},
		{"custom missing type", func(i map[string]any) { i["ImageOwnerAlias"] = "self" }, unknownType},
		{"shared missing type", func(i map[string]any) { i["ImageOwnerAlias"] = "others" }, unknownType},
		{"marketplace missing type", func(i map[string]any) { i["ImageOwnerAlias"] = "marketplace" }, unknownType},
		{"owner missing", func(i map[string]any) { delete(i, "ImageOwnerAlias") }, unknownType},
		{"size omitted", func(i map[string]any) { delete(imageMappingForTest(i), "Size") }, invalidSize},
		{"size empty", func(i map[string]any) { imageMappingForTest(i)["Size"] = "" }, invalidSize},
		{"size not integer", func(i map[string]any) { imageMappingForTest(i)["Size"] = "20.5" }, invalidSize},
		{"size zero", func(i map[string]any) { imageMappingForTest(i)["Size"] = "0" }, invalidSize},
		{"size negative", func(i map[string]any) { imageMappingForTest(i)["Size"] = "-20" }, invalidSize},
		{"size overflow", func(i map[string]any) { imageMappingForTest(i)["Size"] = "999999999999999999999999999999" }, invalidSize},
		{"size mismatch", func(i map[string]any) { imageMappingForTest(i)["Size"] = "21" }, invalidSize},
		{"size exceeds template", func(i map[string]any) { imageMappingForTest(i)["Size"] = "80"; i["Size"] = 80 }, ""},
		{"top size zero", func(i map[string]any) { i["Size"] = 0 }, ""},
		{"image ID changed", func(i map[string]any) { i["ImageId"] = "other-image" }, ""},
		{"not Linux", func(i map[string]any) { i["OSType"] = "windows" }, ""},
		{"OS type missing", func(i map[string]any) { delete(i, "OSType") }, ""},
		{"architecture mismatch", func(i map[string]any) { i["Architecture"] = "arm64" }, ""},
		{"image unavailable", func(i map[string]any) { i["Status"] = "UnAvailable" }, ""},
	}
	key := fixtureKey(t)
	input := createInput(key)
	for _, stage := range []string{"prepare", "create"} {
		for _, tc := range tests {
			t.Run(stage+"/"+tc.name, func(t *testing.T) {
				imageChecks := 0
				base := fixtureAPI(t, key, func(action string, _ url.Values, out map[string]any) error {
					if action == "DescribeImages" {
						imageChecks++
						item := out["Images"].(map[string]any)["Image"].([]map[string]any)[0]
						delete(imageMappingForTest(item), "Type")
						tc.mutate(item)
					}
					return nil
				})
				api := fake(func(ctx context.Context, service, action, region string, query url.Values, out any) error {
					if action != "DescribeImages" && !(stage == "prepare" && action == "DescribeVpcs" && imageChecks == 0) {
						t.Fatalf("invalid image permitted further API action: %s", action)
					}
					return base(ctx, service, action, region, query, out)
				})
				var err error
				if stage == "prepare" {
					_, err = prepare(context.Background(), api, fixture(), input)
				} else {
					_, err = create(context.Background(), api, fixture(), input)
				}
				if err == nil || imageChecks != 1 {
					t.Fatalf("unsafe image accepted or unchecked: err=%v, image checks=%d", err, imageChecks)
				}
				want := tc.want
				if stage == "prepare" && want != "" {
					want = "镜像检查：" + want
				}
				if want != "" && err.Error() != want {
					t.Fatalf("got %q, want %q", err, want)
				}
			})
		}
	}
}

func imageMappingForTest(item map[string]any) map[string]any {
	return item["DiskDeviceMappings"].(map[string]any)["DiskDeviceMapping"].([]map[string]any)[0]
}

func emptyImageMappingShapes() map[string]func(map[string]any) {
	return map[string]func(map[string]any){
		"mapping omitted": func(i map[string]any) { delete(i, "DiskDeviceMappings") },
		"mapping null":    func(i map[string]any) { i["DiskDeviceMappings"] = nil },
		"mapping empty":   func(i map[string]any) { i["DiskDeviceMappings"] = map[string]any{} },
		"list null":       func(i map[string]any) { i["DiskDeviceMappings"] = map[string]any{"DiskDeviceMapping": nil} },
		"list empty":      func(i map[string]any) { i["DiskDeviceMappings"] = map[string]any{"DiskDeviceMapping": []any{}} },
	}
}

func TestEmptyImageMappingsOnlyAllowedForOfficialSource(t *testing.T) {
	for _, owner := range []string{"system", "self", "others", "marketplace", "", "unknown"} {
		for shape, change := range emptyImageMappingShapes() {
			t.Run(owner+"/"+shape, func(t *testing.T) {
				api := fixtureAPI(t, nil, func(action string, _ url.Values, out map[string]any) error {
					if action != "DescribeImages" {
						t.Fatalf("unexpected action: %s", action)
					}
					item := out["Images"].(map[string]any)["Image"].([]map[string]any)[0]
					item["ImageOwnerAlias"] = owner
					change(item)
					return nil
				})
				err := preflightImage(context.Background(), api, fixture())
				if (err == nil) != (owner == "system") {
					t.Fatalf("owner=%q empty mapping=%q: %v", owner, shape, err)
				}
			})
		}
	}
}

func TestOfficialImageWithoutMappingsPreparesAndCreates(t *testing.T) {
	key := fixtureKey(t)
	input := createInput(key)
	for shape, change := range emptyImageMappingShapes() {
		t.Run(shape, func(t *testing.T) {
			checks, purchases := 0, 0
			api := fixtureAPI(t, key, func(action string, query url.Values, out map[string]any) error {
				switch action {
				case "DescribeImages":
					checks++
					change(out["Images"].(map[string]any)["Image"].([]map[string]any)[0])
				case "RunInstances":
					purchases++
					if query.Get("SystemDisk.Size") != "40" || query.Get("Amount") != "1" {
						t.Fatal("public image fallback changed single-instance system disk policy")
					}
					for field := range query {
						if len(field) >= len("DataDisk.") && field[:len("DataDisk.")] == "DataDisk." {
							t.Fatal("public image fallback generated a data disk")
						}
					}
				}
				return nil
			})
			if got, err := prepare(context.Background(), api, fixture(), input); err != nil || got.KeyID != input.KeyID || purchases != 0 {
				t.Fatalf("prepare: %+v, %v, purchases=%d", got, err, purchases)
			}
			if got, err := create(context.Background(), api, fixture(), input); err != nil || got.InstanceID != "i-fixture" || purchases != 1 || checks != 2 {
				t.Fatalf("create: %+v, %v, purchases=%d, checks=%d", got, err, purchases, checks)
			}
		})
	}
}

func TestOfficialEmptyMappingsStillValidateImageBeforeWrites(t *testing.T) {
	key := fixtureKey(t)
	input := createInput(key)
	for shape, change := range emptyImageMappingShapes() {
		for _, metadata := range []struct {
			name  string
			value any
		}{
			{"ImageId", "other-image"}, {"Status", "Creating"},
			{"OSType", "windows"}, {"OSType", ""}, {"Architecture", "arm64"},
			{"Size", nil}, {"Size", 0}, {"Size", -1}, {"Size", 80},
		} {
			for _, stage := range []string{"prepare", "create"} {
				t.Run(shape+"/"+metadata.name+"/"+stage, func(t *testing.T) {
					checks := 0
					base := fixtureAPI(t, key, func(action string, _ url.Values, out map[string]any) error {
						if action == "DescribeImages" {
							checks++
							item := out["Images"].(map[string]any)["Image"].([]map[string]any)[0]
							change(item)
							item[metadata.name] = metadata.value
						}
						return nil
					})
					api := fake(func(ctx context.Context, service, action, region string, query url.Values, out any) error {
						if action != "DescribeImages" && !(stage == "prepare" && action == "DescribeVpcs" && checks == 0) {
							t.Fatalf("invalid public image continued with %s", action)
						}
						return base(ctx, service, action, region, query, out)
					})
					var err error
					if stage == "prepare" {
						_, err = prepare(context.Background(), api, fixture(), input)
					} else {
						_, err = create(context.Background(), api, fixture(), input)
					}
					if err == nil || checks != 1 {
						t.Fatalf("invalid public image accepted: %v, checks=%d", err, checks)
					}
				})
			}
		}
	}
}

func TestOfficialImageMalformedMappingsAreNotTreatedAsEmpty(t *testing.T) {
	for name, mappings := range map[string]any{
		"container array": []any{},
		"container text":  "",
		"list object":     map[string]any{"DiskDeviceMapping": map[string]any{}},
		"list text":       map[string]any{"DiskDeviceMapping": ""},
		"null element":    map[string]any{"DiskDeviceMapping": []any{nil}},
		"empty element":   map[string]any{"DiskDeviceMapping": []any{map[string]any{}}},
		"numeric type":    map[string]any{"DiskDeviceMapping": []any{map[string]any{"Type": 1, "Size": "20"}}},
		"numeric size":    map[string]any{"DiskDeviceMapping": []any{map[string]any{"Type": "system", "Size": 20}}},
	} {
		t.Run(name, func(t *testing.T) {
			api := fixtureAPI(t, nil, func(action string, _ url.Values, out map[string]any) error {
				if action != "DescribeImages" {
					t.Fatalf("unexpected action: %s", action)
				}
				out["Images"].(map[string]any)["Image"].([]map[string]any)[0]["DiskDeviceMappings"] = mappings
				return nil
			})
			if err := preflightImage(context.Background(), api, fixture()); err == nil {
				t.Fatal("malformed public image mapping accepted as empty")
			}
		})
	}
}
