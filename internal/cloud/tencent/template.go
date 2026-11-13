// Package tencent implements the narrow CVM lifecycle used by LastOrder.
// It never accepts cloud endpoints, credentials or arbitrary API parameters
// from a packaged template.
package tencent

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
	RegionLabel  string     `json:"regionLabel"`
	Region       string     `json:"region"`
	RunInstances Parameters `json:"runInstances"`
}

type Parameters struct {
	Placement    struct{ Zone string } `json:"Placement"`
	InstanceType string                `json:"InstanceType"`
	ImageID      string                `json:"ImageId"`
	SystemDisk   struct {
		DiskType string
		DiskSize int
	} `json:"SystemDisk"`
	InternetAccessible struct {
		InternetChargeType      string
		InternetMaxBandwidthOut int
		PublicIpAssigned        bool
	} `json:"InternetAccessible"`
}

var (
	regionPattern   = regexp.MustCompile(`^[a-z]{2}-[a-z]+(?:-[a-z]+)*$`)
	tokenPattern    = regexp.MustCompile(`^[a-zA-Z0-9_-]{16,64}$`)
	instancePattern = regexp.MustCompile(`^ins-[a-z0-9]+$`)
	errTemplate     = errors.New("腾讯云模板无效，请检查模板字段、地域、镜像、网络和按量计费配置")
)

func parseTemplate(raw json.RawMessage) (Template, error) {
	var t Template
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&t) != nil || d.Decode(new(any)) != io.EOF || t.Validate() != nil {
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
		t.CPU < 1 || t.CPU > 1024 || t.MemoryGB < 1 || t.MemoryGB > 1024 || t.DiskGB < 20 || t.DiskGB > 4096 ||
		(t.Architecture != "x64" && t.Architecture != "arm64") || t.OS != "Ubuntu 24.04 LTS" || !regionPattern.MatchString(t.Region) ||
		!matches(`^`+regexp.QuoteMeta(t.Region)+`-[1-9][0-9]*$`, p.Placement.Zone) || !matches(`^[A-Z][A-Za-z0-9]*\.[A-Z0-9]+$`, p.InstanceType) ||
		!matches(`^img-[a-z0-9]+$`, p.ImageID) ||
		p.SystemDisk.DiskSize != t.DiskGB || !p.InternetAccessible.PublicIpAssigned || p.InternetAccessible.InternetChargeType != "TRAFFIC_POSTPAID_BY_HOUR" ||
		p.InternetAccessible.InternetMaxBandwidthOut < 1 || p.InternetAccessible.InternetMaxBandwidthOut > 100 {
		return errTemplate
	}
	switch p.SystemDisk.DiskType {
	case "CLOUD_PREMIUM", "CLOUD_SSD", "CLOUD_BSSD", "CLOUD_HSSD":
		return nil
	default:
		return errTemplate
	}
}
