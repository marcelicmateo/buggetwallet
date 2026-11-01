// wallet-build is Budget Wallet's build tool: the Go port of tools/build.sh and its helpers.
// `wallet-build [-q] <command> [args…]`; the command list is in internal/cli/usage.txt.
package main

import (
	"os"

	"wallet-build/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], os.Environ(), os.Stdout, os.Stderr))
}
