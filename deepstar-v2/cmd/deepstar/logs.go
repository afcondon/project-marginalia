package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"

	"github.com/afcondon/deepstar-v2/internal/registry"
)

// runLogs implements SPEC §8.6 — tail one service log, or multiplex
// all with a `[name]` prefix.  No --tier filter; logs reads only
// the file system, doesn't touch state or signal anything.
func runLogs(ctx *cmdContext, args []string) int {
	lFlags := flag.NewFlagSet("logs", flag.ContinueOnError)
	lFlags.SetOutput(os.Stderr)
	if err := lFlags.Parse(args); err != nil {
		return exitUsage
	}

	logDir := os.Getenv("DEEPSTAR_LOG_DIR")
	if logDir == "" {
		logDir = "/tmp/deepstar"
	}

	if lFlags.NArg() == 1 {
		name := lFlags.Arg(0)
		path := filepath.Join(logDir, name+".log")
		cmd := exec.Command("tail", "-F", "-n", "50", path)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "deepstar logs %s: %v\n", name, err)
			return exitFailure
		}
		return exitOK
	}

	// Multiplex all registered services.
	r, err := registry.LoadFile(ctx.ConfigPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar logs: %v\n", err)
		return exitConfigAction
	}
	services, err := r.Tier(ctx.Tier)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar logs: %v\n", err)
		return exitConfigAction
	}

	var (
		mu sync.Mutex
		wg sync.WaitGroup
	)
	for _, svc := range services {
		path := filepath.Join(logDir, svc.Name+".log")
		wg.Add(1)
		go func(name, path string) {
			defer wg.Done()
			cmd := exec.Command("tail", "-F", "-n", "10", path)
			pipe, err := cmd.StdoutPipe()
			if err != nil {
				return
			}
			cmd.Stderr = cmd.Stdout // merge
			if err := cmd.Start(); err != nil {
				return
			}
			scanLines(name, pipe, &mu)
			_ = cmd.Wait()
		}(svc.Name, path)
	}
	wg.Wait()
	return exitOK
}

// scanLines reads lines from r and writes them to os.Stdout under
// a shared mutex, prefixed with [name].
func scanLines(name string, r io.Reader, mu *sync.Mutex) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		mu.Lock()
		fmt.Printf("[%s] %s\n", name, sc.Text())
		mu.Unlock()
	}
}
