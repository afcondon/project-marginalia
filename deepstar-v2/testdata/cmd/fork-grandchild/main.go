// fork-grandchild spawns a child which in turn spawns a grandchild;
// each role sleeps until SIGTERM/SIGINT.  Used by §10.2 to verify
// group-kill terminates the whole tree — DeepStar's stored identity
// is the group leader (the parent role here), and the test asserts
// that after `down`, the grandchild is also gone.
//
// Each role prints its pid + parent pid + group pid to stderr so the
// harness can record the expected tree.
package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
)

func main() {
	role := flag.String("role", "parent", "parent | child | grandchild")
	port := flag.Int("port", 0, "TCP port for parent role to bind (0 = none)")
	flag.Parse()

	// Parent optionally binds a port so deepstar's health check has
	// something to probe.  Child/grandchild never bind.
	if *role == "parent" && *port > 0 {
		l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
		if err != nil {
			fmt.Fprintf(os.Stderr, "fork-grandchild: parent listen tcp:%d: %v\n", *port, err)
			os.Exit(1)
		}
		defer l.Close()
	}

	var child *exec.Cmd
	switch *role {
	case "parent":
		child = spawn("child")
	case "child":
		child = spawn("grandchild")
	case "grandchild":
		// leaf; just sleep
	default:
		fmt.Fprintf(os.Stderr, "fork-grandchild: unknown role %q\n", *role)
		os.Exit(2)
	}

	fmt.Fprintf(os.Stderr, "fork-grandchild role=%s pid=%d ppid=%d pgid=%d\n",
		*role, os.Getpid(), os.Getppid(), pgid())

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	s := <-sig
	fmt.Fprintf(os.Stderr, "fork-grandchild role=%s received %s, exiting\n", *role, s)

	// Reap our child if we spawned one — it received the same SIGTERM
	// via the group and is exiting; waiting here means the process tree
	// unwinds bottom-up rather than leaving zombies for launchd.
	if child != nil {
		_ = child.Wait()
	}
}

func spawn(nextRole string) *exec.Cmd {
	c := exec.Command(os.Args[0], "--role", nextRole)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	if err := c.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "fork-grandchild: spawn %s: %v\n", nextRole, err)
		os.Exit(1)
	}
	return c
}

func pgid() int {
	g, err := syscall.Getpgid(os.Getpid())
	if err != nil {
		return -1
	}
	return g
}
