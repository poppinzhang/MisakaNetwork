package volcengine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"sort"
	"strings"
)

type AvailableZones struct {
	Zones []string `json:"zones"`
}

type availableResource struct {
	Type               string
	SupportedResources *[]struct{ Value, Status string }
}
type availableZone struct {
	RegionID           string `json:"RegionId"`
	ZoneID             string `json:"ZoneId"`
	Status             string
	AvailableResources *[]availableResource
}

// DescribeAvailableResource returns a nested inventory snapshot, not a
// reservation. The zone-level status covers all resources, so checking it
// alone cannot prove that the unchanged requested instance type is available.
// https://docs.volcengine.com/docs/ecs/describeavailableresource?lang=zh
func availableZones(ctx context.Context, api caller, t Template) (AvailableZones, error) {
	var out struct{ AvailableZones *[]availableZone }
	if err := api.call(ctx, "ecs", "DescribeAvailableResource", t.Region, params(
		"DestinationResource", "InstanceType",
		"InstanceTypeId", t.RunInstances.InstanceTypeID,
		"InstanceChargeType", "PostPaid",
		"SpotStrategy", "NoSpot",
	), &out); err != nil {
		return AvailableZones{}, err
	}
	invalid := errors.New("火山引擎可用区库存响应不完整或与所选地域不匹配")
	if out.AvailableZones == nil || len(*out.AvailableZones) > 100 {
		return AvailableZones{}, invalid
	}
	seen := map[string]bool{}
	count := 0
	for _, zone := range *out.AvailableZones {
		if zone.RegionID != t.Region || !zoneValid(t.Region, zone.ZoneID) ||
			(zone.Status != "Available" && zone.Status != "SoldOut") ||
			zone.AvailableResources == nil || len(*zone.AvailableResources) > 100 {
			return AvailableZones{}, invalid
		}
		matched, sell := false, true
		for _, resources := range *zone.AvailableResources {
			if !textOK(resources.Type, 64) || resources.SupportedResources == nil || len(*resources.SupportedResources) > 100 {
				return AvailableZones{}, invalid
			}
			for _, resource := range *resources.SupportedResources {
				count++
				if count > 4096 || !textOK(resource.Value, 128) || (resource.Status != "Available" && resource.Status != "SoldOut") {
					return AvailableZones{}, invalid
				}
				if resources.Type != "InstanceType" || resource.Value != t.RunInstances.InstanceTypeID {
					continue
				}
				matched = true
				// A conflicting duplicate anywhere in the same zone excludes it.
				sell = sell && resource.Status == "Available"
			}
		}
		prior, exists := seen[zone.ZoneID]
		seen[zone.ZoneID] = matched && sell && zone.Status == "Available" && (!exists || prior)
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

// A separate type prevents a generic cloud error, a preflight error or a
// malformed HTTP response from being mistaken for an acknowledged refusal.
type capacityRejection struct{ code, requestID string }

func (e *capacityRejection) Error() string { return (&apiError{e.code}).Error() }

func capacityCode(code string) bool {
	// These are RunInstances' documented HTTP 500 business rejections. Never
	// expand this to the Insufficient prefix (which includes account balance).
	// https://docs.volcengine.com/docs/ecs/runinstances-createsinstances?lang=zh
	return code == "Insufficient.InstanceCapacity" || code == "Insufficient.VolumePoolCapacity"
}

// Confirm only the documented envelope without success fields. In addition to
// Result being absent/null/empty, reject duplicate keys and extra envelope or
// metadata fields: JSON's last-key-wins behavior must not erase a success ID or
// contradictory error and authorize another billable purchase.
func unambiguousRejectionEnvelope(data []byte) bool {
	if !uniqueJSONDocument(data) {
		return false
	}
	var envelope map[string]json.RawMessage
	if json.Unmarshal(data, &envelope) != nil || len(envelope) == 0 {
		return false
	}
	for key := range envelope {
		if key != "ResponseMetadata" && key != "Result" {
			return false
		}
	}
	if result, present := envelope["Result"]; present && !bytes.Equal(bytes.TrimSpace(result), []byte("null")) {
		var object map[string]json.RawMessage
		if json.Unmarshal(result, &object) != nil || object == nil || len(object) != 0 {
			return false
		}
	}
	var metadata map[string]json.RawMessage
	if json.Unmarshal(envelope["ResponseMetadata"], &metadata) != nil || metadata == nil {
		return false
	}
	for key := range metadata {
		switch key {
		case "RequestId", "Action", "Version", "Service", "Region", "Error":
		default:
			return false
		}
	}
	var cloudError map[string]json.RawMessage
	if json.Unmarshal(metadata["Error"], &cloudError) != nil || cloudError == nil {
		return false
	}
	for key := range cloudError {
		if key != "Code" && key != "Message" && key != "CodeN" {
			return false
		}
	}
	if number, exists := cloudError["CodeN"]; exists {
		var value int64
		if json.Unmarshal(number, &value) != nil || value <= 0 {
			return false
		}
	}
	if message, exists := cloudError["Message"]; exists {
		var value string
		if json.Unmarshal(message, &value) != nil {
			return false
		}
	}
	return true
}

func uniqueJSONDocument(data []byte) bool {
	d := json.NewDecoder(bytes.NewReader(data))
	if !uniqueJSONValue(d, 0) {
		return false
	}
	_, err := d.Token()
	return err == io.EOF
}

func uniqueJSONValue(d *json.Decoder, depth int) bool {
	if depth > 32 {
		return false
	}
	token, err := d.Token()
	if err != nil {
		return false
	}
	delimiter, compound := token.(json.Delim)
	if !compound {
		return true
	}
	if delimiter != '{' && delimiter != '[' {
		return false
	}
	keys := map[string]bool{}
	for d.More() {
		if delimiter == '{' {
			key, err := d.Token()
			value, ok := key.(string)
			folded := strings.ToLower(value)
			if err != nil || !ok || keys[folded] {
				return false
			}
			keys[folded] = true
		}
		if !uniqueJSONValue(d, depth+1) {
			return false
		}
	}
	end, err := d.Token()
	return err == nil && ((delimiter == '{' && end == json.Delim('}')) || (delimiter == '[' && end == json.Delim(']')))
}
