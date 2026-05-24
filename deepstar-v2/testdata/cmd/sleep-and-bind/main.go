// sleep-and-bind binds a port or unix socket, then sleeps until
// SIGTERM/SIGINT.  Used by §10 fixtures as a stand-in for a real
// daemon — establishes a port-bound, signal-cooperative process that
// the test harness can manage like cv-router / link-spike / etc.
package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	var (
		port int
		kind string
		path string
	)
	flag.IntVar(&port, "port", 0, "TCP/UDP port to bind")
	flag.StringVar(&kind, "kind", "tcp", "tcp | udp | unix")
	flag.StringVar(&path, "path", "", "unix socket path (required when kind=unix)")
	flag.Parse()

	closer, err := bind(kind, port, path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "sleep-and-bind: %v\n", err)
		os.Exit(1)
	}
	defer closer()

	fmt.Fprintf(os.Stderr, "sleep-and-bind: bound %s pid=%d\n", describe(kind, port, path), os.Getpid())

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	s := <-sig
	fmt.Fprintf(os.Stderr, "sleep-and-bind: received %s, exiting\n", s)
}

func bind(kind string, port int, path string) (func(), error) {
	switch kind {
	case "tcp":
		l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			return nil, fmt.Errorf("tcp listen: %w", err)
		}
		return func() { _ = l.Close() }, nil
	case "udp":
		addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			return nil, fmt.Errorf("udp resolve: %w", err)
		}
		c, err := net.ListenUDP("udp", addr)
		if err != nil {
			return nil, fmt.Errorf("udp listen: %w", err)
		}
		return func() { _ = c.Close() }, nil
	case "unix":
		if path == "" {
			return nil, fmt.Errorf("kind=unix requires --path")
		}
		_ = os.Remove(path)
		l, err := net.Listen("unix", path)
		if err != nil {
			return nil, fmt.Errorf("unix listen: %w", err)
		}
		return func() { _ = l.Close(); _ = os.Remove(path) }, nil
	default:
		return nil, fmt.Errorf("unknown kind: %q", kind)
	}
}

func describe(kind string, port int, path string) string {
	if kind == "unix" {
		return "unix:" + path
	}
	return fmt.Sprintf("%s:%d", kind, port)
}
