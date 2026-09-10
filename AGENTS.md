# Working on the huddle

Read [README.md](README.md) first for what this is and how it is laid out.

## Gates

All three must pass before committing:

```bash
pytest tests/ -q
shellcheck lib/*.sh bin/huddle-hook
ruff check .
```

CI runs the same three.

## Bump the version, or your change will not ship

Claude Code copies the plugin into `~/.claude/plugins/cache/huddle/huddle/<version>/`
and keys the cache on the version string. `claude plugin update huddle@huddle`
compares versions and no-ops when they match, so editing a file here and running
update leaves the old copy installed and running — silently.

Every change that should reach a running session bumps the version in all four
places: `plugin.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
and `.codex-plugin/plugin.json`. `claude plugin tag` checks that the manifest and
the marketplace entry agree.

Antigravity reads the symlinked working tree directly, so it needs no bump — which
makes it the fastest place to test a change, and an easy way to be fooled into
thinking Claude Code picked one up.

## Rules that are easy to break by accident

**Never change a hook command string in a manifest.** `.codex-plugin/plugin.json`,
`hooks/hooks.json`, and `hooks.json` all name `bin/huddle-hook <event>`. Codex
hashes each handler definition to decide whether to trust it, so editing a
command — or reordering matcher groups — silently stops the hook from running
while it still reports as enabled. Put behavior changes inside `bin/huddle-hook`.

**Codex's plugin manifest tolerates no unknown top-level keys.** A stray field in
`.codex-plugin/plugin.json` fails the parse and drops every hook in it, not just
the offending one.

**`hooks.json` and `hooks/hooks.json` are different documents.** The root one is
Antigravity's, namespaced by hook name, with camelCase payloads and `injectSteps`
for context injection. The one in `hooks/` is Claude Code's, with snake_case
payloads and `hookSpecificOutput.additionalContext`. Never symlink them.

**Scripts locate their siblings with `dirname "$0"`.** Adapters do the same with
`__dirname`. Everything in `lib/` must stay flat and in `lib/` or that seam
breaks, along with the test fixture that copies adapters beside script doubles.

**No repository-specific identifiers in user-facing output.** The trusted
registry lives at `~/.config/agents-huddle/repos.json`, outside this repository,
and nothing here should assume a particular repo, remote, or bead prefix beyond
the existing defaults.

## Layout note

`lib/` holds the implementation. `bin/huddle-hook` is the only thing hooks name.
`skills/huddle/SKILL.md` is shared verbatim by all three harnesses and is the
place for conventions rather than mechanics.

## Issue tracking

Work on the huddle is tracked in this repository's own beads project, prefix
`HDDL`. It is an embedded Dolt database under `.beads/`, gitignored, with its
history pushed to `refs/dolt/data` on this repository's git origin — so the data
travels with the repo without ever appearing as tracked files.

**The `HDDL` project is not the huddle channel.** The channel — the coordination
posts that sessions read and write at runtime — lives in whatever beads project
the repository being worked on uses, which today is PinPoint's `PP`. A session
coordinating work in PinPoint posts to `PP`; a session fixing a bug in the huddle
files it as `HDDL`. Nothing here routes channel traffic to `HDDL`, and nothing
should.

Re-running `bd init` here re-adds a Claude/Codex/skill scaffold this repository
deliberately does not carry, and re-commits `.beads/`. Don't.
