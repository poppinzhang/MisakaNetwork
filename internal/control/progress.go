package control

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
)

// DeploymentProgress contains only predefined phases and approximate completion,
// never request data, remote output, credentials, or local paths.
type DeploymentProgress struct {
	Percent int    `json:"percent"`
	Stage   string `json:"stage"`
}

type progressReporter struct {
	path string
	last DeploymentProgress
}

func newProgressReporter(path string) (*progressReporter, error) {
	r := &progressReporter{path: path, last: DeploymentProgress{Percent: -1}}
	if path == "" {
		return r, nil
	}
	if !filepath.IsAbs(path) {
		return nil, errors.New("部署进度文件路径无效")
	}
	// Never replace an existing file supplied by a caller, including symlinks.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, errors.New("无法创建部署进度文件")
	}
	if err = f.Close(); err != nil {
		return nil, errors.New("无法创建部署进度文件")
	}
	if err = ProtectPath(path); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *progressReporter) report(percent int, stage string) {
	if r == nil || percent < r.last.Percent || percent > 100 {
		return
	}
	value := DeploymentProgress{Percent: percent, Stage: stage}
	if value == r.last {
		return
	}
	r.last = value
	if r.path == "" {
		return
	}
	// Readers see a complete snapshot. A missed progress write must never abort
	// activation/rollback; completion is determined by the final helper response.
	f, err := os.CreateTemp(filepath.Dir(r.path), ".deployment-progress-")
	if err != nil {
		return
	}
	defer os.Remove(f.Name())
	if ProtectPath(f.Name()) != nil {
		f.Close()
		return
	}
	err = json.NewEncoder(f).Encode(value)
	closeErr := f.Close()
	if err == nil && closeErr == nil {
		_ = os.Rename(f.Name(), r.path)
	}
}

type uploadProgressReader struct {
	reader io.Reader
	total  int64
	read   int64
	report func(int, string)
}

func (r *uploadProgressReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	r.read += int64(n)
	if n > 0 && r.total > 0 {
		fraction := min(float64(r.read)/float64(r.total), 1)
		r.report(20+int(55*fraction), "上传并解压安装包")
	}
	return n, err
}
