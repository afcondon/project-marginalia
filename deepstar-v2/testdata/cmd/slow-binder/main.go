// slow-binder sleeps for --delay before binding --port (TCP), then
// sleeps until SIGTERM/SIGINT.  Used by §10.4 to verify per-service
// health-timeout policy: with --delay 8s and health_timeout_ms=3000
// the service must fail cleanly with a named timeout error; with
// health_timeout_ms=12000 it must succeed.
package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	port := flag.Int("port", 0, "TCP port to bind after delay")
	delay := flag.Duration("delay", 0, "delay before binding (e.g. 8s)")
	flag.Parse()

	fmt.Fprintf(os.Stderr, "slow-binder: pid=%d sleeping %s before binding tcp:%d\n",
		os.Getpid(), *delay, *port)
	time.Sleep(*delay)

	l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		fmt.Fprintf(os.Stderr, "slow-binder: listen: %v\n", err)
		os.Exit(1)
	}
	defer l.Close()
	fmt.Fprintf(os.Stderr, "slow-binder: bound tcp:%d\n", *port)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	s := <-sig
	fmt.Fprintf(os.Stderr, "slow-binder: received %s, exiting\n", s)
}
