package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/MisakaNetwork/MisakaNetwork/Sisters/agent"
)

func run(ctx context.Context, args []string, out, errOut io.Writer) int {
	if err := checkPlatform(); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	if len(args) == 1 && (args[0] == "--version" || args[0] == "version") {
		fmt.Fprintln(out, "Sisters "+agent.Version)
		return 0
	}
	if len(args) == 0 || (args[0] != "serve" && args[0] != "service") {
		fmt.Fprintln(errOut, "Usage: sisters serve --config <agent.json> | service --config <absolute agent.json> --temp-dir <absolute directory> (Windows) | --version")
		return 2
	}
	serviceMode := args[0] == "service"
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configPath := fs.String("config", "", "JSON configuration file")
	var tempDir string
	if serviceMode {
		fs.StringVar(&tempDir, "temp-dir", "", "private writable temporary directory")
	}
	if fs.Parse(args[1:]) != nil || *configPath == "" || fs.NArg() != 0 {
		fmt.Fprintln(errOut, "Usage: sisters serve --config <agent.json> | service --config <absolute agent.json> --temp-dir <absolute directory> (Windows)")
		return 2
	}
	if serviceMode && (!filepath.IsAbs(*configPath) || !filepath.IsAbs(tempDir)) {
		fmt.Fprintln(errOut, "service requires absolute configuration and temporary directory paths")
		return 2
	}
	c, err := agent.LoadConfig(*configPath)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	if serviceMode {
		err = runService(ctx, c, tempDir)
	} else {
		err = agent.Serve(ctx, c)
	}
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	return 0
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Args[1:], os.Stdout, os.Stderr))
}
