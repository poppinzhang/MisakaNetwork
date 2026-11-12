// Package mobile exposes the control helper inside Android's application process.
package mobile

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
)

const MaxRequestBytes = 1 << 20

// Handle accepts the same envelope as misakactl, with all local paths confined
// to the application sandbox. appRoot is supplied by Android, never by Dart.
func Handle(data []byte, appRoot string) (result []byte) {
	encode := func(response control.Response) []byte {
		out, _ := json.Marshal(response)
		return out
	}
	invalid := func() []byte { return encode(control.Response{Error: "请求格式无效"}) }
	defer func() {
		if recover() != nil {
			result = encode(control.Response{Error: "本地控制服务执行失败"})
		}
	}()
	if len(data) == 0 || len(data) > MaxRequestBytes {
		return invalid()
	}
	var request control.Request
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		return invalid()
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return invalid()
	}
	for _, local := range []string{request.Directory, request.PKIDirectory, request.BundlePath, request.BundlesDirectory, request.PrivateKeyPath, request.ProgressPath} {
		if local != "" && !privatePath(appRoot, local) {
			return encode(control.Response{Error: "文件必须位于应用私有目录"})
		}
	}
	return encode(control.Handle(request))
}

func privatePath(root, candidate string) bool {
	if !filepath.IsAbs(root) || !filepath.IsAbs(candidate) {
		return false
	}
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return false
	}
	// PKI directories need not exist yet. Resolve the nearest existing parent
	// so a symlink inside app storage cannot escape confinement.
	path := filepath.Clean(candidate)
	var missing []string
	for {
		_, err = os.Lstat(path)
		if err == nil {
			break
		}
		if !os.IsNotExist(err) || filepath.Dir(path) == path {
			return false
		}
		missing = append(missing, filepath.Base(path))
		path = filepath.Dir(path)
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return false
	}
	for i := len(missing) - 1; i >= 0; i-- {
		path = filepath.Join(path, missing[i])
	}
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
