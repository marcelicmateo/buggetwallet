package cli

import (
	"bytes"
	"strings"

	"wallet-build/internal/fixtures"
	"wallet-build/internal/logsummary"
	"wallet-build/internal/lspq"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
	"wallet-build/internal/tokenusage"
)

// helpersA runs the ported Python helpers that need no container: fixtures, token-usage, log-summary and lsp-query.
func helpersA(c *run.Ctx, cmd string, rest []string, self string) int {
	switch cmd {
	case "fixtures":
		if len(rest) == 1 && rest[0] == "embed" {
			return fixtures.RunEmbed(c.Root, c.Out, c.Err)
		}
		return fixtures.Run(c.Out, c.Err, rest)
	case "log-summary":
		return logsummary.Run(rest, c.Out, c.Err)
	case "token-usage":
		return tokenUsage(c, rest)
	case "lsp-query":
		start := func() (*lspq.Server, error) { return lspq.Start([]string{self, "lsp"}, c.Env.Environ(), c.Err) }
		return lspq.Main(rest, c.Root, start, c.Out, c.Err)
	}
	return 2
}

const tokenUsageUsage = "usage: token-usage [-h] [--since SINCE] [--until UNTIL] [--json JSON]"

func tokenUsage(c *run.Ctx, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			c.Printf("%s\n\nToken usage of Claude Code sessions in this repo, from the local transcripts under ~/.claude/projects.\n\n"+
				"options:\n  --since SINCE  first day, YYYY-MM-DD\n  --until UNTIL  last day, YYYY-MM-DD (default 9999)\n  --json JSON    also write the summary to this file\n", tokenUsageUsage)
			return 0
		}
	}
	f, ok := parseFlags(args, []string{"--since", "--until", "--json"}, nil)
	if !ok || len(f.pos) > 0 {
		bad := strings.Join(args, " ")
		if ok {
			bad = strings.Join(f.pos, " ")
		}
		c.Eprintf("%s\ntoken-usage: error: unrecognized or incomplete arguments: %s\n", tokenUsageUsage, bad)
		return 2
	}
	git := func(dir string, gargs ...string) (string, int) {
		var buf bytes.Buffer
		rc := c.R.Run(c.Ctx, sys.Cmd{Argv: append([]string{"git"}, gargs...), Dir: dir, Env: c.Env, Stdout: &buf, Stderr: c.Err})
		return buf.String(), rc
	}
	top, rc := git("", "rev-parse", "--show-toplevel")
	if rc != 0 {
		c.Eprintf("token-usage: git rev-parse --show-toplevel failed (exit %d)\n", rc)
		return 1
	}
	o := tokenusage.Opts{Since: f.one("--since"), Until: f.one("--until"), JSON: f.one("--json"), Home: c.Getenv("HOME")}
	return tokenusage.Run(o, strings.TrimSpace(top), git, c.Out, c.Err)
}
