package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
	"io"
	"os"
)

func run(args []string, input io.Reader, output io.Writer) int {
	if len(args) == 1 && args[0] == "--version" {
		fmt.Fprintln(output, control.Version)
		return 0
	}
	invalid := func() int { json.NewEncoder(output).Encode(control.Response{Error: "请求格式无效"}); return 1 }
	if len(args) != 0 {
		return invalid()
	}
	data, err := io.ReadAll(io.LimitReader(input, (1<<20)+1))
	if err != nil || len(data) > 1<<20 {
		return invalid()
	}
	var req control.Request
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		return invalid()
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return invalid()
	}
	resp := control.Handle(req)
	json.NewEncoder(output).Encode(resp)
	if !resp.OK {
		return 1
	}
	return 0
}

func main() { os.Exit(run(os.Args[1:], os.Stdin, os.Stdout)) }
