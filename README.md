# huddle

A coordination channel between parallel agent sessions working on the same
repository. Each session learns what the others did recently, posts its own
updates, and filters out its own echoes — without spending thousands of tokens
at every session start.

It ships as a plugin for **Claude Code**, **Codex**, and **Antigravity** from
this one repository.

## What it does

Sessions talk through beads (`bd`) issues in the host repository's own database:
a long-lived root bead, a daily bead under it, and comments on that daily. Hooks
do the reading and writing, so a session sees peer activity injected into its
context at SessionStart and again — throttled — as it works.

- **SessionStart** injects a work digest, recent peer posts, and identity or
  rotation notices when they are needed.
- **UserPromptSubmit and PostToolUse** poll for new peer comments, throttled so
  the common case costs nothing.
- **PR opened** is announced automatically when a session runs `gh pr create`.
- **PR merged** is announced by a background service, exactly once.

Everything else — the judgment calls about what is worth telling other sessions —
is up to the agent, and the `huddle` skill covers those conventions.

## Layout

```
.claude-plugin/     Claude Code manifest + single-plugin marketplace
.codex-plugin/      Codex manifest, hooks declared inline
.agents/plugins/    Codex marketplace manifest
plugin.json         Antigravity manifest
hooks.json          Antigravity hooks (namespaced by hook name)
hooks/hooks.json    Claude Code hooks
bin/huddle-hook     the single entrypoint every hook command names
lib/                the implementation: shell scripts and two thin adapters
skills/huddle/      the conventions, read by all three harnesses
tests/              pytest suite covering the scripts through subprocess
```

Only the manifests are duplicated, and each is under 60 lines. `lib/` and
`skills/` are shared verbatim by all three harnesses.

Antigravity's root `hooks.json` and Claude Code's `hooks/hooks.json` are
different documents in different formats. Do not symlink them to each other.

## Why one entrypoint

Every hook command in every manifest names `bin/huddle-hook <event>` and nothing
else.

Codex records hook trust as a SHA-256 over each individual handler, keyed
positionally as `<manifest>:<event>:<group>:<handler>`. Editing a command string
— or merely reordering matcher groups — invalidates that hash, and Codex then
reports the hook as enabled while silently never running it. Freezing the
command strings and putting all dispatch inside `bin/huddle-hook` keeps ordinary
changes from quietly breaking Codex.

## Install

The huddle only acts inside repositories listed in a trusted registry at
`~/.config/agents-huddle/repos.json`. That file is personal configuration and is
deliberately not part of this repository; without it, every hook exits silently.

```bash
# Claude Code
/plugin marketplace add ~/Code/huddle
/plugin install huddle@huddle

# Codex
codex plugin marketplace add ~/Code/huddle
codex plugin add huddle@huddle
# then start an interactive `codex` session and choose "Trust all and continue"
# at the "Hooks need review" prompt. SessionStart is not replayed retroactively,
# so start a fresh session afterwards.

# Antigravity
ln -s ~/Code/huddle ~/.gemini/config/plugins/huddle
```

Antigravity runs plugin hooks with no trust step. Dropping a plugin into
`~/.gemini/config/plugins/` is equivalent to allowing it to execute arbitrary
code — install only what you have read.

## Development

```bash
pytest tests/ -q
shellcheck lib/*.sh bin/huddle-hook
ruff check .
```

CI runs the same three gates on every pull request and `main` push.

## License

MIT — see [LICENSE](LICENSE).
