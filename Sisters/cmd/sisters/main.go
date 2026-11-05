package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/MisakaNetwork/MisakaNetwork/Sisters/agent"
)

func run(ctx context.Context, args []string, out, errOut io.Writer) int {
	if len(args) == 1 && (args[0] == "--version" || args[0] == "version") {
		fmt.Fprintln(out, "Sisters "+agent.Version)
		return 0
	}
	if len(args) == 0 || args[0] != "serve" {
		fmt.Fprintln(errOut, "Usage: sisters serve --config <agent.json> | --version")
		return 2
	}
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configPath := fs.String("config", "", "JSON configuration file")
	if fs.Parse(args[1:]) != nil || *configPath == "" || fs.NArg() != 0 {
		fmt.Fprintln(errOut, "Usage: sisters serve --config <agent.json>")
		return 2
	}
	c, err := agent.LoadConfig(*configPath)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	if err := agent.Serve(ctx, c); err != nil {
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
