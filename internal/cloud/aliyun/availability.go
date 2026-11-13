package aliyun

import (
	"context"
	"errors"
	"sort"
)

type AvailableZones struct {
	Zones []string `json:"zones"`
}

func availableZones(ctx context.Context, api caller, t Template) (AvailableZones, error) {
	var out struct {
		AvailableZones *struct {
			AvailableZone *[]struct {
				ZoneId, RegionId, Status, StatusCategory string
				AvailableResources                       *struct {
					AvailableResource *[]struct {
						Type               string
						SupportedResources *struct {
							SupportedResource *[]struct{ Value, Status, StatusCategory string }
						}
					}
				}
			}
		}
	}
	if e := api.call(ctx, "ecs", "DescribeAvailableResource", t.Region, params("DestinationResource", "InstanceType", "InstanceChargeType", "PostPaid", "SpotStrategy", "NoSpot", "IoOptimized", "optimized", "InstanceType", t.RunInstances.InstanceType), &out); e != nil {
		return AvailableZones{}, e
	}
	if out.AvailableZones == nil || out.AvailableZones.AvailableZone == nil {
		return AvailableZones{}, errors.New("阿里云可用区库存响应异常，请稍后重试")
	}
	seen := map[string]bool{}
	for _, z := range *out.AvailableZones.AvailableZone {
		if z.RegionId != t.Region || !zonePattern(t.Region).MatchString(z.ZoneId) || z.AvailableResources == nil || z.AvailableResources.AvailableResource == nil {
			return AvailableZones{}, errors.New("阿里云可用区库存与所选地域不匹配或响应不完整")
		}
		offered := false
		found := false
		for _, r := range *z.AvailableResources.AvailableResource {
			if r.Type != "InstanceType" {
				continue
			}
			if r.SupportedResources == nil || r.SupportedResources.SupportedResource == nil {
				return AvailableZones{}, errors.New("阿里云可用区规格库存响应异常")
			}
			for _, v := range *r.SupportedResources.SupportedResource {
				if v.Value != t.RunInstances.InstanceType {
					continue
				}
				sell := v.Status == "Available" && v.StatusCategory == "WithStock"
				if found {
					offered = offered && sell
				} else {
					offered = sell
				}
				found = true
			}
		}
		sell := found && offered && z.Status == "Available" && z.StatusCategory == "WithStock"
		prior, exists := seen[z.ZoneId]
		seen[z.ZoneId] = sell && (!exists || prior)
	}
	result := AvailableZones{Zones: []string{}}
	for zone, sell := range seen {
		if sell {
			result.Zones = append(result.Zones, zone)
		}
	}
	sort.Strings(result.Zones)
	return result, nil
}
func zoneUnavailable(e error) bool {
	var cloud *apiError
	if !errors.As(e, &cloud) {
		return false
	}
	switch cloud.code {
	case "OperationDenied.NoStock", "Zone.NotOnSale", "InvalidInstanceType.ZoneNotSupported", "InstanceType.Offline":
		return true
	}
	return false
}
