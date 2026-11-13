// Package volcengine implements LastOrder's narrow, authenticated ECS lifecycle.
// Templates cannot supply credentials, API endpoints or lifecycle parameters.
package volcengine

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
	ZoneID         string        `json:"ZoneId"`
	InstanceTypeID string        `json:"InstanceTypeId"`
	ImageID        string        `json:"ImageId"`
	Volumes        []Volume      `json:"Volumes"`
	EipAddress     EipParameters `json:"EipAddress"`
}
type Volume struct {
	VolumeType string
	Size       int
}
type EipParameters struct {
	BandwidthMbps       int
	ISP, ChargeType     string
	ReleaseWithInstance bool
}

var (
	regionPattern   = regexp.MustCompile(`^[a-z]{2}-[a-z]+(?:-[a-z0-9]+)*$`)
	tokenPattern    = regexp.MustCompile(`^[a-zA-Z0-9_-]{16,64}$`)
	instancePattern = regexp.MustCompile(`^i-[a-z0-9]+$`)
	eipPattern      = regexp.MustCompile(`^eip-[a-z0-9]+$`)
	errTemplate     = errors.New("火山引擎模板无效，请检查地域、镜像、系统盘与按流量公网 IP 配置")
)

func matches(pattern, value string) bool { return regexp.MustCompile(pattern).MatchString(value) }
func textOK(s string, max int) bool {
	return s != "" && s == strings.TrimSpace(s) && utf8.RuneCountInString(s) <= max && !strings.ContainsFunc(s, unicode.IsControl)
}
func parseTemplate(raw json.RawMessage) (Template, error) {
	var t Template
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if len(raw) > 1<<20 || d.Decode(&t) != nil || d.Decode(new(any)) != io.EOF || t.Validate() != nil {
		return Template{}, errTemplate
	}
	return t, nil
}
func (t Template) Validate() error {
	p := t.RunInstances
	if !matches(`^[a-z][a-z0-9-]{0,63}$`, t.ID) || !textOK(t.Name, 80) || !textOK(t.Description, 500) || !textOK(t.RegionLabel, 80) || t.CPU < 1 || t.CPU > 1024 || t.MemoryGB < 1 || t.MemoryGB > 1024 || t.DiskGB < 20 || t.DiskGB > 2048 ||
		(t.Architecture != "x64" && t.Architecture != "arm64") || !textOK(t.OS, 128) || !matches(`^[a-z_][a-z0-9_-]{0,31}$`, t.SSHUsername) || !regionPattern.MatchString(t.Region) || !zoneValid(t.Region, p.ZoneID) || !matches(`^ecs\.[a-zA-Z0-9-]+\.[a-zA-Z0-9]+$`, p.InstanceTypeID) || !matches(`^image-[a-z0-9]+$`, p.ImageID) || len(p.Volumes) != 1 || p.Volumes[0].Size != t.DiskGB || (p.Volumes[0].VolumeType != "ESSD_PL0" && p.Volumes[0].VolumeType != "ESSD_FlexPL") || p.EipAddress.BandwidthMbps < 1 || p.EipAddress.BandwidthMbps > 200 || p.EipAddress.ISP != "BGP" || p.EipAddress.ChargeType != "PayByTraffic" || !p.EipAddress.ReleaseWithInstance {
		return errTemplate
	}
	return nil
}

func zoneValid(region, zone string) bool {
	separator := "-"
	if matches(`[0-9]$`, region) {
		separator = ""
	}
	return matches(`^`+regexp.QuoteMeta(region)+separator+`[a-z]$`, zone)
}
