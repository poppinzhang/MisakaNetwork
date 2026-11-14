package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"
)

const runtimeFixtureEnv = "MISAKA_AGENT_TEST_RUNTIME_FIXTURE"

type runtimeFixture struct {
	Frames      []string
	ExitCode    int
	Wait        bool
	Child       bool
	Host        bool
	Marker      string
	ChildMarker string
}

// Reexecute the test binary instead of depending on /bin/sh. All inputs are
// synthetic; this hook exists only in the test binary, never in Sisters.
func TestMain(m *testing.M) {
	if raw := os.Getenv(runtimeFixtureEnv); raw != "" {
		var fixture runtimeFixture
		if err := json.Unmarshal([]byte(raw), &fixture); err != nil {
			os.Exit(2)
		}
		if fixture.Host {
			path, _ := os.Executable()
			cmd := exec.CommandContext(context.Background(), path)
			fixture.Host = false
			data, _ := json.Marshal(fixture)
			cmd.Env = append(os.Environ(), runtimeFixtureEnv+"="+string(data))
			cleanup, err := startIsolatedProcess(cmd)
			if err != nil {
				os.Exit(6)
			}
			defer cleanup()
			time.Sleep(time.Minute)
			os.Exit(0)
		}
		_, _ = io.Copy(io.Discard, os.Stdin)
		if fixture.Child {
			path, _ := os.Executable()
			child := exec.Command(path)
			child.Stdout, child.Stderr = os.Stdout, os.Stderr
			data, _ := json.Marshal(runtimeFixture{Wait: true, Marker: fixture.ChildMarker})
			child.Env = append(os.Environ(), runtimeFixtureEnv+"="+string(data))
			if child.Start() != nil {
				os.Exit(3)
			}
			if fixture.ChildMarker != "" {
				deadline := time.Now().Add(10 * time.Second)
				for {
					if _, err := os.Stat(fixture.ChildMarker); err == nil {
						break
					}
					if time.Now().After(deadline) {
						os.Exit(4)
					}
					time.Sleep(time.Millisecond)
				}
			}
		}
		for _, frame := range fixture.Frames {
			fmt.Fprintln(os.Stdout, frame)
		}
		if fixture.Marker != "" {
			if os.WriteFile(fixture.Marker, []byte(strconv.Itoa(os.Getpid())), 0600) != nil {
				os.Exit(5)
			}
		}
		if fixture.Wait {
			time.Sleep(time.Minute)
		}
		os.Exit(fixture.ExitCode)
	}
	os.Exit(m.Run())
}

func fixtureRunner(t *testing.T, fixture runtimeFixture) executableRunner {
	t.Helper()
	data, err := json.Marshal(fixture)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(runtimeFixtureEnv, string(data))
	// Race binaries otherwise wait one second on every helper exit.
	t.Setenv("GORACE", "atexit_sleep_ms=0")
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return executableRunner{path: path}
}
