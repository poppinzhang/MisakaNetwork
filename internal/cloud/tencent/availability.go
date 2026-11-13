package tencent

import (
	"context"
	"errors"
	"regexp"
	"sort"
)

type AvailableZones struct {
	Zones []string `json:"zones"`
}

// Inventory is a hint, never a reservation. Only return the unchanged instance
// type and billing mode in the template's region; RunInstances still decides
// whether the exact image/disk/network configuration can be fulfilled.
func availableZones(ctx context.Context, api caller, t Template) (AvailableZones, error) {
	var out struct {
		InstanceTypeQuotaSet *[]struct {
			Zone, InstanceType, InstanceChargeType, Status string
		}
	}
	if err := api.call(ctx, "cvm", "DescribeZoneInstanceConfigInfos", t.Region, map[string]any{
		"Filters": []any{filter("instance-type", t.RunInstances.InstanceType), filter("instance-charge-type", "POSTPAID_BY_HOUR")},
	}, &out); err != nil {
		return AvailableZones{}, err
	}
	if out.InstanceTypeQuotaSet == nil {
		return AvailableZones{}, errors.New("腾讯云可用区库存响应异常，请稍后重试")
	}
	seen := map[string]bool{}
	for _, item := range *out.InstanceTypeQuotaSet {
		if item.InstanceType != t.RunInstances.InstanceType || item.InstanceChargeType != "POSTPAID_BY_HOUR" {
			continue
		}
		if !matches(`^`+regexp.QuoteMeta(t.Region)+`-[1-9][0-9]*$`, item.Zone) {
			return AvailableZones{}, errors.New("腾讯云可用区库存与所选地域不匹配")
		}
		// Conflicting duplicate entries are conservatively treated as unsold.
		prior, exists := seen[item.Zone]
		seen[item.Zone] = item.Status == "SELL" && (!exists || prior)
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

// Only an explicit refusal of this RunInstances request permits a different
// zone. Broad error prefixes also include quota, configuration and unknown
// outcome failures, so they must never trigger another purchase.
func zoneUnavailable(err error) bool {
	var apiErr *apiError
	if !errors.As(err, &apiErr) {
		return false
	}
	switch apiErr.code {
	case "ResourceInsufficient.AvailabilityZoneSoldOut",
		"ResourceInsufficient.CloudDiskSoldOut",
		"ResourceInsufficient.InsufficientOfferingMinimum",
		"ResourceInsufficient.SpecifiedInstanceType",
		"ResourceUnavailable.InstanceType",
		"ResourcesSoldOut.SpecifiedInstanceType",
		"InvalidParameterValue.ZoneNotSupported":
		return true
	default:
		return false
	}
}
