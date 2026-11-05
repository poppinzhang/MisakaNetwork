package control

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"strings"
	"unicode"
)

type Manifest struct {
	Version     string `json:"version"`
	BiliVersion string `json:"bili_version"`
	Platform    string `json:"platform"`
	Arch        string `json:"arch"`
}

// CheckBundle rejects traversal, devices and unsafe symlinks before streaming to tar.
func CheckBundle(file, platform, arch string) error {
	f, e := os.Open(file)
	if e != nil {
		return errors.New("缺少对应平台的离线部署包，请使用完整发行包")
	}
	defer f.Close()
	return checkBundleReader(f, platform, arch)
}

func checkBundleReader(source io.Reader, platform, arch string) error {
	gz, e := gzip.NewReader(source)
	if e != nil {
		return errors.New("部署包压缩格式无效")
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	var m Manifest
	found := map[string]*tar.Header{}
	links := map[string]string{}
	var total int64
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return errors.New("部署包归档数据无效")
		}
		n := path.Clean(h.Name)
		if n == "." && h.Typeflag == tar.TypeDir {
			continue
		}
		original := strings.TrimSuffix(h.Name, "/")
		original = strings.TrimPrefix(original, "./")
		if n == "." || n != original || path.IsAbs(n) || n == ".." || strings.HasPrefix(n, "../") || strings.Contains(n, "\\") || strings.ContainsFunc(n, unicode.IsControl) {
			return errors.New("部署包包含不安全路径")
		}
		if found[n] != nil {
			return errors.New("部署包包含重复条目")
		}
		if len(found) >= 100000 {
			return errors.New("部署包文件数量超过限制")
		}
		found[n] = h
		total += h.Size
		if h.Size < 0 || total > 2<<30 {
			return errors.New("部署包超过允许大小")
		}
		switch h.Typeflag {
		case tar.TypeReg, tar.TypeRegA, tar.TypeDir:
		case tar.TypeSymlink:
			if h.Linkname == "" || path.IsAbs(h.Linkname) || strings.Contains(h.Linkname, "\\") || strings.ContainsFunc(h.Linkname, unicode.IsControl) {
				return errors.New("部署包包含不安全链接")
			}
			links[n] = h.Linkname
		default:
			return errors.New("部署包包含不支持的文件类型")
		}
		if n == "manifest.json" {
			if h.Typeflag != tar.TypeReg && h.Typeflag != tar.TypeRegA {
				return errors.New("部署清单必须为普通文件")
			}
			if h.Size > 4096 {
				return errors.New("部署清单过大")
			}
			d := json.NewDecoder(tr)
			if e = d.Decode(&m); e != nil {
				return errors.New("部署清单无效")
			}
			var extra any
			if d.Decode(&extra) != io.EOF {
				return errors.New("部署清单必须为单个 JSON 对象")
			}
		}
	}
	// Consume gzip's footer to reject truncation/checksum corruption after tar's
	// end marker. The extracted tar still receives exactly the validated archive.
	tail, e := io.ReadAll(io.LimitReader(gz, 1024*1024+1))
	if e != nil || len(tail) > 1024*1024 || len(bytes.Trim(tail, "\x00")) != 0 {
		return errors.New("部署包压缩校验或尾部数据无效")
	}
	for n, h := range found {
		for parent := path.Dir(n); parent != "."; parent = path.Dir(parent) {
			if entry := found[parent]; entry != nil && entry.Typeflag != tar.TypeDir {
				return errors.New("部署包文件路径穿过非目录条目")
			}
		}
		if h.Typeflag == tar.TypeSymlink {
			if !safeLinkTarget(n, links) {
				return errors.New("部署包包含越界或循环链接")
			}
		}
	}
	for _, n := range []string{"sisters", "runtime/misaka-runtime"} {
		h := found[n]
		if h == nil || (h.Typeflag != tar.TypeReg && h.Typeflag != tar.TypeRegA) || h.Size == 0 {
			return errors.New("部署包缺少可执行文件")
		}
	}
	for _, n := range []string{"config.json", "ca.pem", "server.pem", "server.key"} {
		if found[n] != nil {
			return errors.New("部署包不得包含私有配置或证书")
		}
	}
	if m.Version != Version || m.BiliVersion != BiliVersion || m.Platform != platform || m.Arch != arch {
		return errors.New("部署包版本、平台或文件不匹配")
	}
	return nil
}

// Resolve symlinks component by component, including links followed by '..'.
// Cleaning a target lexically first would hide escapes through another link.
func safeLinkTarget(name string, links map[string]string) bool {
	pending := strings.Split(name, "/")
	stack := []string{}
	hops := 0
	for len(pending) > 0 {
		part := pending[0]
		pending = pending[1:]
		switch part {
		case "", ".":
			continue
		case "..":
			if len(stack) == 0 {
				return false
			}
			stack = stack[:len(stack)-1]
			continue
		}
		candidate := strings.Join(append(append([]string(nil), stack...), part), "/")
		if target, ok := links[candidate]; ok {
			hops++
			if hops > 40 {
				return false
			}
			pending = append(strings.Split(target, "/"), pending...)
		} else {
			stack = append(stack, part)
		}
	}
	return true
}
