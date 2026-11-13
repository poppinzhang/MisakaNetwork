// Package aliyun implements the narrow ECS lifecycle used by LastOrder.
// It never accepts cloud endpoints, credentials or arbitrary API parameters
// from a packaged template.
package aliyun

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

type Template struct {
	ID           string     `json:"id"`
	Name         string     `json:"name"`
	Description  string     `json:"description"`
	CPU          int        `json:"cpu"`
	MemoryGB     int        `json:"memoryGb"`
	DiskGB       int        `json:"diskGb"`
	Architecture string     `json:"architecture"`
	OS           string     `json:"os"`
	SSHUsername  string     `json:"sshUsername"`
	RegionLabel  string     `json:"regionLabel"`
	Region       string     `json:"region"`
	RunInstances Parameters `json:"runInstances"`
}

type Parameters struct {
	ZoneID       string `json:"ZoneId"`
	InstanceType string `json:"InstanceType"`
	ImageID      string `json:"ImageId"`
	SystemDisk   struct {
		Category string
		Size     int
	} `json:"SystemDisk"`
	InternetChargeType      string `json:"InternetChargeType"`
	InternetMaxBandwidthOut int    `json:"InternetMaxBandwidthOut"`
}

var (
	regionPattern   = regexp.MustCompile(`^[a-z]{2}-[a-z]+(?:-[a-z0-9]+)*$`)
	tokenPattern    = regexp.MustCompile(`^[a-zA-Z0-9_-]{16,64}$`)
	instancePattern = regexp.MustCompile(`^i-[a-z0-9]+$`)
	errTemplate     = errors.New("阿里云模板无效，请检查模板字段、地域、镜像、网络和按量计费配置")
)

func parseTemplate(raw json.RawMessage) (Template, error) {
	var t Template
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if len(raw) > 1<<20 || !uniqueJSON(raw) || d.Decode(&t) != nil || d.Decode(new(any)) != io.EOF || t.Validate() != nil {
		return Template{}, errTemplate
	}
	return t, nil
}

func textOK(s string, max int) bool {
	return s != "" && s == strings.TrimSpace(s) && utf8.RuneCountInString(s) <= max && !strings.ContainsFunc(s, unicode.IsControl)
}

func matches(pattern, value string) bool { return regexp.MustCompile(pattern).MatchString(value) }

func (t Template) Validate() error {
	p := t.RunInstances
	if !matches(`^[a-z][a-z0-9-]{0,63}$`, t.ID) || !textOK(t.Name, 80) || !textOK(t.Description, 500) || !textOK(t.RegionLabel, 80) ||
		t.CPU < 1 || t.CPU > 1024 || t.MemoryGB < 1 || t.MemoryGB > 1024 || t.DiskGB < 20 || t.DiskGB > 2048 ||
		(t.Architecture != "x64" && t.Architecture != "arm64") || !textOK(t.OS, 128) || !matches(`^[a-z_][a-z0-9_-]{0,31}$`, t.SSHUsername) || !regionPattern.MatchString(t.Region) ||
		!zonePattern(t.Region).MatchString(p.ZoneID) || !matches(`^ecs\.[a-zA-Z0-9-]+\.[a-zA-Z0-9]+$`, p.InstanceType) ||
		!matches(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$`, p.ImageID) ||
		p.SystemDisk.Size != t.DiskGB || p.InternetChargeType != "PayByTraffic" ||
		p.InternetMaxBandwidthOut < 1 || p.InternetMaxBandwidthOut > 100 {
		return errTemplate
	}
	switch p.SystemDisk.Category {
	case "cloud_efficiency", "cloud_ssd", "cloud_essd", "cloud_essd_entry", "cloud_auto":
		return nil
	default:
		return errTemplate
	}
}

func zonePattern(region string) *regexp.Regexp {
	separator := "-"
	last := region[len(region)-1]
	if last >= '0' && last <= '9' {
		separator = ""
	}
	return regexp.MustCompile(`^` + regexp.QuoteMeta(region) + separator + `[a-z]$`)
}
