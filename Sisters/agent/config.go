// Package agent implements the mutually authenticated Sisters task service.
package agent

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
)

const Version = "0.1.5"

// Config paths are resolved relative to the configuration file by LoadConfig.
type Config struct {
	Listen          string `json:"listen"`
	Cert            string `json:"cert"`
	Key             string `json:"key"`
	CA              string `json:"ca"`
	Runtime         string `json:"runtime"`
	MaxConcurrency  int    `json:"max_concurrency"`
	QueueCapacity   int    `json:"queue_capacity,omitempty"`
	HistoryCapacity int    `json:"history_capacity,omitempty"`
}

func LoadConfig(path string) (Config, error) {
	var c Config
	f, err := os.Open(path)
	if err != nil {
		return c, errors.New("cannot open agent configuration")
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 64*1024+1))
	d.DisallowUnknownFields()
	if err := d.Decode(&c); err != nil {
		return c, errors.New("invalid agent configuration JSON")
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return c, errors.New("configuration must contain one JSON object")
	}
	base, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		return c, errors.New("cannot resolve configuration directory")
	}
	for _, p := range []*string{&c.Cert, &c.Key, &c.CA, &c.Runtime} {
		if *p != "" && !filepath.IsAbs(*p) {
			*p = filepath.Join(base, *p)
		}
	}
	return c, c.normalize()
}

func (c *Config) normalize() error {
	if c.Listen == "" {
		c.Listen = "127.0.0.1:7443"
	}
	if _, _, err := net.SplitHostPort(c.Listen); err != nil {
		return errors.New("listen must be a host:port address")
	}
	if c.Cert == "" || c.Key == "" || c.CA == "" {
		return errors.New("server certificate, key and client CA are required")
	}
	if c.Runtime == "" {
		return errors.New("runtime executable is required")
	}
	if c.MaxConcurrency == 0 {
		c.MaxConcurrency = 2
	}
	if c.QueueCapacity == 0 {
		c.QueueCapacity = 64
	}
	if c.HistoryCapacity == 0 {
		c.HistoryCapacity = 1000
	}
	if c.MaxConcurrency < 1 || c.MaxConcurrency > 32 {
		return errors.New("max_concurrency must be between 1 and 32")
	}
	if c.QueueCapacity < 1 || c.QueueCapacity > 4096 {
		return errors.New("queue_capacity must be between 1 and 4096")
	}
	if c.HistoryCapacity < c.MaxConcurrency+c.QueueCapacity || c.HistoryCapacity > 10000 {
		return errors.New("history_capacity must cover running and queued tasks and be at most 10000")
	}
	return nil
}

// ServerTLS has no insecure fallback: a trusted client certificate is mandatory.
func ServerTLS(c Config) (*tls.Config, error) {
	pair, err := tls.LoadX509KeyPair(c.Cert, c.Key)
	if err != nil {
		return nil, errors.New("cannot load server TLS certificate and key")
	}
	pem, err := os.ReadFile(c.CA)
	if err != nil {
		return nil, errors.New("cannot load client CA")
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, errors.New("client CA contains no valid certificate")
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}, ClientCAs: pool, ClientAuth: tls.RequireAndVerifyClientCert}, nil
}
