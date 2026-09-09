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
