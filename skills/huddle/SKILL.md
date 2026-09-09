---
name: huddle
description: The conventions behind the inter-session coordination channel that the global huddle hooks inject but do not state — which events are auto-posted versus the judgment calls only you can post (added scope is the most-skipped and most-needed), peer-response etiquette, the em-dash self-filter signature, identity registration, and rotation. Also covers the trusted repository registry, XDG agent state, the updater and leader services, the work digest, poll controls, and service health. Use when posting to the Huddle, choosing between Beads comments and notes, seeing a rotation-needed notice, deciding whether something is worth posting, receiving a peer update, diagnosing self-filter/noise/null-lookups, or checking service health.
---

# huddle

The huddle system is a context-efficient channel between parallel sessions working on the same repo. Each session learns what other sessions did recently, posts its own updates, and filters out its own echoes — all without consuming thousands of tokens at every session start.

**The code ships as a plugin; the channel stays per repo.** Scripts are at
`<huddle>/lib/` — `~/Code/huddle/lib/` on this machine — and repositories are
enabled only by the trusted registry at `~/.config/agents-huddle/repos.json`,
which is personal configuration and deliberately not part of this repository.
Harness hooks may fire in any working directory, but the shared resolver exits
silently unless the cwd belongs to a registered canonical clone or one of its
linked worktrees and the checkout still matches its configured GitHub remote.

Agent-writable state lives under
`${XDG_STATE_HOME:-$HOME/.local/state}/agents-huddle/agent/<repo-id>/`. The
trusted registry and the service subtree are outside the agents' writable
boundary. Repository fetch state, service locks, health, and logs live under the
sibling `service/<repo-id>/` subtree owned by the updater/leader user service.

Tests are `~/Code/huddle/tests/`. CI runs these gates on every pull request and
`main` push. After editing a script, run the same gates locally:

```bash
cd ~/Code/huddle && pytest tests/ -q && shellcheck lib/*.sh bin/huddle-hook && ruff check .
```

The hooks (`huddle-session-start.sh` at SessionStart, `huddle-poll.sh` at UserPromptSubmit and throttled PostToolUse) do the injection. The bootstrap and registration notices carry their own commands, including the naming format and examples; the rotation notice points back here for its dispatch. This skill is the part the hooks don't print: the conventions, the knobs, and why they are what they are.

## Codex hook trust

Installing the plugin is not authorization. Codex trusts hooks as a SHA-256 per
individual handler, keyed positionally, so after first install — or any change
to a hook command in `.codex-plugin/plugin.json` — the user must approve them in
an interactive Codex session ("Hooks need review" → "Trust all and continue").
Codex may report an untrusted hook as enabled while silently omitting it from
execution, so file presence and a healthy Huddle service do not prove a Codex
task is polling.

This is why every hook command names `bin/huddle-hook` and nothing else: the
trust hash covers the handler definition, so keeping those command strings
frozen means routine changes to the huddle never silently revoke trust. Change
behavior inside `bin/huddle-hook`, not in the manifest.

Complete the rollout with a fresh Codex task and a controlled peer comment on
the active daily bead. The task must receive that comment through hook
injection. Keep trust user-consented through `/hooks`; do not write Codex's
private `[hooks.state]` hashes on the user's behalf.

## Reading the work digest

The digest is what merged to `main` grouped by work type plus which branches are alive. `huddle-digest.sh` builds it from the local git object store — **no LLM, no network, no `bd`** — so it costs a few milliseconds and can't go stale in the way a hand-written summary does.

Read it as orientation, not as instructions: it tells you what kind of work this project is doing right now, which is the thing the daily summaries below it don't convey. Because it reads `origin/main` as-is and never fetches, it labels the newest commit date it actually saw — if that date looks old, your remote refs are stale, not the project.

## Identity

Sign your huddle comments with `—<YourFullRegisteredName>` (em-dash + your full registered name). The self-filter matches this suffix to suppress your own echoes.

### Where the name comes from

A session carries three names, and they are set by three different things. The
huddle name is the only one you control; keeping the other two in step is a
handoff, not an API call.

| Name                  | Set by                             | Seen in                            |
| --------------------- | ---------------------------------- | ---------------------------------- |
| Huddle name           | `huddle-whoami.sh register` — you  | Bead signatures, self-filter       |
| Display name          | `/rename` — the user only          | `ListAgents` peers, terminal title |
| herdr workspace label | the user, creating the workspace   | herdr sidebar                      |

**Derive the huddle name from the workspace label.** The user already typed a name for
this session when they made its workspace, so it says what the session is for
without you guessing. The registration notice reads it and prints a CamelCased
candidate. When the label is generic — `PinPoint`, `Orchestrating`, `Busywork`,
`main`, a bare number — name yourself after the bead the user pointed you at instead;
fall back to the task only when there is neither.

**In Claude Code, then ask the user to run `/rename <YourName>`,** at the end of your next
response. It is the only way the Claude display name gets set, and you
cannot do it yourself: `/rename` is registered `type: local-jsx` with
`requires: {ink: true}`, so it needs the interactive terminal UI and no tool
reaches it. (`--name` at launch would work but fires before the task is known.)
Don't block on the answer. Confirmed to propagate to both surfaces: a peer that
listed as `pinpoint-11 [a8cc65]` listed as `crabbox-lease-staleness-fix [a8cc65]`
after its rename, and the terminal title changes in the same instant.

Codex does not expose the same useful interactive rename contract, so its
registration notice deliberately does not ask for `/rename`. The Huddle name is
still registered and used for attribution and self-filtering.

**Put the command alone on its own line.** The user copies it by triple-clicking,
which selects the entire line — so a line that also holds prose, backticks,
leading indentation, or a trailing period pastes all of that into the prompt
with the command. Ask in a sentence, then give the bare command on the next
line, blank line above and below:

> Registered as Claude-RenamePrompt. When you get a chance:
>
> /rename Claude-RenamePrompt

The bare form is deliberate: inline backticks are copied literally, and a fenced
code block is rendered with its own indentation. Neither survives a paste into
the prompt as a working slash command.

The notice reads the label from **`$HERDR_WORKSPACE_ID`**, not by matching panes.
Hooks inherit the environment herdr launched the agent in, so the variable is
right there and names the workspace directly. Both alternatives are traps:
`herdr pane list`'s `agent_session.value` has been measured pointing at a
_different live session_ (see the `herdr` skill), and `terminal_title` carries
Claude Code's animating activity glyph, which `terminal_title_stripped` only
partly removes — `✳` and the braille frames yes, `◐`/`◑` no.

`$HERDR_WORKSPACE_ID` goes stale in a forked session, after a handoff, and on a
**moved pane**. The moved pane is the one that misleads: the lookup is
live-by-id, so it returns the _current_ label of a _different_ workspace and the
notice offers a plausible name belonging to someone else's task. Tolerable here
and nowhere else in the huddle, because the result is a _suggestion_ you and the user
both read before it is registered — never a signature attributed silently.

**Any hook that reads herdr needs a hard timeout.** `.claude/settings.json` caps
this hook at 5000ms and it already runs ~4s. Exceeding the cap is not a degraded
notice: Claude Code kills the hook and discards **all** of its stdout, so the
session learns no session_id, never registers, and re-injects its own posts —
the PP-2m3l breakage. The lookup is wrapped in `timeout 1` (the call itself
measures ~9ms), and with neither `timeout` nor `gtimeout` present it is skipped
rather than run unbounded.

No herdr — a bare terminal, another harness — and the notice silently
drops to bead-then-task. Nothing errors. The notice is harness-neutral: it says
`<Harness>-` rather than `Claude-`, and makes the rename step conditional on the
harness having such a command, because Antigravity and Codex run this same hook
through the global Antigravity adapter.

**A session_id belongs to whoever registered it first.** `register` refuses to
rebind a session_id that already holds a different name — no silent overwrite,
which used to rename the owning session out from under it and corrupt huddle
attribution (PP-788v). If you meant to rename **your own** session, re-run with
`--force`. If you were _handed_ a session_id by another agent, it is not yours:
don't register, just sign your posts.

### Self-filter rules

- Comments are filtered by exact suffix match: `—<YourName>` (shorthand) or `—Claude-<YourName>` (canonical).
- The em-dash (U+2014) distinguishes from hyphen-minus — no false positives between `—Claude-Spinner` and `—Spinner`.
- If your name gets pruned (14-day inactivity) and your own past posts start re-injecting, re-register: `bash ~/Code/huddle/lib/huddle-whoami.sh register <Name> <session_id>`.

### Subagent sessions

Subagent sessions (`Agent({...})` dispatches) are skipped entirely — both hooks exit 0 without output. Subagents should not register names or post coordination updates; they're ephemeral.

**`huddle-whoami.sh` enforces this, it isn't just guidance.** `register` and `discover` refuse outright when the caller is a dispatched subagent. There is no `--force` for this, because a subagent has no correct id to supply: `CLAUDE_CODE_SESSION_ID` holds the **parent's** id, the transcript heuristic only sees top-level transcripts, and the scratchpad path embeds the parent's UUID. Every route returns the parent (PP-788v — three consecutive subagents overwrote the orchestrator's own mapping in one night; "just tell agents to use their own id" was tried twice and failed, because that value doesn't exist in a subagent's environment).

**Detection is by transcript path — the same `*/subagents/*` signal the two hooks use.** A hook gets its transcript path in the payload; a script invoked from the Bash tool has to find its own record, so `huddle-whoami.sh` scans the trailing records of `<project>/<session>.jsonl` and every `<project>/<session>/subagents/*.jsonl` for the newest record that **invokes** the script. That record identifies the caller, because the harness writes a tool_use record to the **calling** agent's transcript — but only _usually_ before the command runs, which is why two bounds sit on top of it:

- **Freshness.** Records older than 120s are ignored, not merely outranked. The flush is not guaranteed: a top-level `discover` was observed running with its own record still unwritten, and lost to an 18-minute-old record a subagent had left behind — the session was told it was a subagent. Anything that stale says nothing about the process running now.
- **Command position, not mention.** The match requires a Bash `tool_use` whose command _runs_ the script — start of command, start of a line, or after `;`/`&`/`|`, optionally behind `bash`/`sh`. A raw substring match counted `rg`-ing or editing the file, which flipped the verdict in both directions.

An indeterminate read — no fresh matching record, another harness, an invocation behind an unrecognised wrapper such as `timeout 5 bash …` — is treated as "not a subagent"; the rebind guard in `register` is the backstop. That bias is deliberate: a missed subagent still meets the rebind guard, while a false refusal locks a session out with nothing to catch it.

Detection used to key off `CLAUDE_CODE_CHILD_SESSION` plus an `AI_AGENT` ending in `_agent`. That was wrong, and on 2026-08-08 it locked every Claude session on the machine out of registering (PP-uxnn): Claude Code puts both markers into **every** shell the Bash tool spawns — `source: "agent"` there means "the model is spawning this process", not "dispatched subagent" — so the predicate was true for top-level sessions too. A top-level session and a dispatched subagent were measured to carry identical `AI_AGENT`, `CLAUDE_CODE_CHILD_SESSION` and `CLAUDE_CODE_SESSION_ID` values. Don't reach for an env marker here; there isn't one.

If you're a subagent that needs to say something in the huddle: post the comment and sign it `—<YourName>`. A signature needs no registration.

## Bootstrap

Bootstrap runs once per local clone; the session-start notice prints the command. Re-running is safe — it's a no-op if already bootstrapped, printing current state.

**Historical archive:** PP-cvh contains coordination activity prior to bootstrap. It stays open as a read-only reference; no one writes there after bootstrap runs.

## Rotation

The session-start notice routes here for the dispatch. **First, post a heads-up on the active daily bead**, then dispatch. Peer sessions poll that bead; a heads-up tells them a rotation is already underway so they don't fire their own subagent. (The rotation file-lock already makes a double-dispatch a safe no-op — this just saves peers a wasted subagent.) At this moment `today_bead.id` still points to the current, pre-rotation daily — that's the bead peers are polling, so it's the right place to post:

```bash
TODAY_BEAD="$(bash -c 'source "$HOME/Code/huddle/lib/huddle-lib.sh"; huddle_today_bead_id')"
bd comments add "$TODAY_BEAD" "Kicking off huddle rotation → <today's date>. —<YourFullRegisteredName>"
```

Then use this `Agent` call (adjust model as appropriate):

```javascript
Agent({
  subagent_type: "claude",
  model: "claude-sonnet-4-5",
  prompt: `
You are the huddle rotation subagent. Your job is to rotate the daily coordination bead.

**Phase A — run the shell script:**

  output=$(bash ~/Code/huddle/lib/huddle-rotate.sh)
  echo "$output"

Parse the output for key=value lines:
- OLD_TODAY=<id>       — yesterday's daily bead to summarize + close
- OLD_MONTHLY=<id>     — last month's monthly bead (only present if month rolled)
- OLD_MONTH=<name>     — the month label (e.g. "2026-05") of the old monthly
- NEW_TODAY=<id>       — today's fresh daily bead (now active)
- NEW_MONTHLY=<id>     — current monthly bead
- ROTATION_DATE=<date> — the rotation date

If the script exits 0 with no output, a peer already rotated — exit immediately
with "No-op: peer rotated first."

**Phase B — LLM summarization (only if OLD_TODAY is present):**

1. Fetch OLD_TODAY's comments:
     bd comments <OLD_TODAY> --json

2. Write a tight categorized summary into OLD_TODAY's description:
   - Categories (omit empty ones): Merged/Ships, In-flight, Discoveries, Blockers
   - ~30-50 tokens per category; bullet list per category
   - Run: bd update <OLD_TODAY> --description "<summary>"

3. Archive raw comments into OLD_TODAY's notes (JSON array for forensics):
   - Format: [{"author":"...","created_at":"...","text":"..."},...]
   - Run: bd update <OLD_TODAY> --notes '<json-array>'

4. Close OLD_TODAY:
     bd close <OLD_TODAY>

5. If month rolled (OLD_MONTHLY present):
   a. Read OLD_MONTHLY's comments or collect recent daily descriptions for that month
   b. Write monthly rollup summary into OLD_MONTHLY's description
   c. Close OLD_MONTHLY: bd close <OLD_MONTHLY>

6. Prune stale session names (§8.4 of the design spec):
   a. Resolve the state directory with
      `source ~/Code/huddle/lib/huddle-lib.sh; huddle_state_dir`, then read its
      session-names.json
   b. For each {session_id: name} entry, scan the last 14 days of huddle content
      (today's bead + recent daily archives + monthly summaries) for sign-offs
      matching "—<name>" or "—Claude-<name>"
   c. Evict entries with no match in 14 days
   d. Atomically write the pruned map back to that session-names.json

After phase B, report: "Rotation complete. OLD_TODAY=<id> closed. NEW_TODAY=<id> active."
`,
});
```

The subagent acquires a file lock in phase A. If a peer session already rotated, phase A exits immediately — safe to dispatch even if you're unsure.

## Responding to peers

**Peer-response etiquette:** when a peer's kickoff or update scrolls by, reply only if you have _specific relevant context_ — a conflict with what they're touching, a gotcha you hit there, a related in-flight branch or bead. Don't ack-spam ("sounds good", "noted") — silence is the correct response when you have nothing concrete to add.

### The quiet-session nudge

**Why it exists:** the kickoff is not the failure point — the silence after it is. A session announces a plan, then the user adds a second ask, or review feedback grows the change, or a one-line fix turns into a refactor, and peers spend hours coordinating against a plan that stopped being true. Added scope is the single most under-reported thing in the huddle, which is why the nudge names it first.

If nothing actually changed, ignore the nudge. A bare "still working on it" is noise.

### Turning the volume down

Nothing prints these, so they live here:

- `HUDDLE_NUDGE_SECONDS=0` disables the quiet-session nudge. It otherwise fires at most once per window per session, never on a session's first poll, and never when you've posted inside the window.
- `HUDDLE_THROTTLE_SECONDS` caps how often the PostToolUse poll runs. Claude's global hook sets 180 seconds; Codex's global hook sets 60 seconds. The script itself defaults to `0` (every tool call), which is for debugging only.
- To stop PostToolUse polling entirely, remove the corresponding global hook entry for the harness (`~/.claude/settings.json` or `~/.codex/hooks.json`). UserPromptSubmit polling continues regardless.

## How to post coordination updates

### Live channel contract

The active daily bead's **comments are the live Huddle channel**. Every manual
kickoff, added-scope update, direction change, finding, or coordination request
is one `bd comments add` record. This gives the poller a distinct event with an
author and timestamp, and rotation later archives those same records.

Keep the two Beads writes distinct when one event needs both durable task
context and peer coordination:

| Destination | Purpose | Command |
|---|---|---|
| The actual task bead | Durable implementation breadcrumbs | `bd note PP-task "..."` |
| The active Huddle daily bead | Live peer broadcast | `bd comments add "$TODAY_BEAD_ID" "... —<YourName>"` |

Resolve the daily bead, post, and verify the exact comment:

```bash
TODAY_BEAD_ID="$(bash -c 'source "$HOME/Code/huddle/lib/huddle-lib.sh"; huddle_today_bead_id')"
HUDDLE_UPDATE="Your update here. —<YourName>"
bd comments add "$TODAY_BEAD_ID" "$HUDDLE_UPDATE"
bd comments "$TODAY_BEAD_ID" --json | jq -e --arg text "$HUDDLE_UPDATE" 'any(.[]; .text == $text)'
```

Completion means the write printed `Comment added to <daily-id>` and the exact
text query succeeded. `Note added to <daily-id>` means the update was written
to the wrong surface: immediately repost the peer-facing text with
`bd comments add`, verify it, and mention the correction if peers need to know
why the update arrived late.

**Storage guardrail:** live agents write daily comments. The rotation subagent
alone replaces a daily bead's Notes with the raw comment archive; Huddle state
scripts own the root bead's Notes; monthly Notes are not a posting surface.
`bd note`, `bd update --notes`, and `bd update --append-notes` therefore never
target a Huddle daily, monthly, or root bead during ordinary session work. A
live update written into daily Notes is invisible to polling and is overwritten
by rotation, so signing that text does not make it a Huddle post.

**Two events are auto-posted — you don't need to post these manually:**

- **Merge** (`~/Code/huddle/lib/huddle-service.sh`, `leader` role): after the next service fetch observes a squash merge, it posts `Merged PR #N: title` exactly once. The first run baselines without replay; a failed post retains the cursor for retry.
- **PR opened** (`~/Code/huddle/lib/huddle-pr-announce.sh` PostToolUse hook): when you call `gh pr create` (Bash) or `mcp__github__create_pull_request`, the hook auto-posts "Opened PR #N (PP-xxx): title." Dedup-safe — re-fires are ignored.

A launchd job runs the service every minute in the `leader` role: it fetches,
may fast-forward a clean canonical checkout on its configured main branch, and
is the only writer of merge announcements. The lesser `updater` role fetches but
never announces, and exists for a second machine that should not duplicate the
announcements. Hooks never perform Git maintenance. Inspect the service with:

```bash
bash ~/Code/huddle/lib/huddle-service.sh status
```

**What still requires a manual post** (the judgment calls automation can't make):

- **A session kickoff** — once per session, after you understand the goal, for substantive work or investigations (not trivial Q&A or one-line fixes): "Starting: <what> in <area/branch>. Ping me if you have context." This lets parallel sessions learn about your work early — before something ships — so anyone with a relevant gotcha, conflict, or in-flight branch can chime in.
- **Scope that got ADDED to what you're already doing** — the user tacks a second ask onto the session, review feedback grows the change, a "quick fix" turns out to need a migration. Say what got added, not just that something did: "PP-xxx grew to also cover <thing> — now touching <area>." **This is the most commonly skipped post and the one peers most need**, because the kickoff they read is now describing work you're no longer only doing.
- **A change of direction** — you dropped the approach you announced. Peers may have decisions pending on it.
- A bead you filed for a non-obvious finding: "Filed PP-xxx: <finding>."
- A coordination need — file/area conflict risk: "Working on <file/area> in <branch>; flag if conflict."

Things NOT worth posting:

- Every single commit
- Internal debugging chatter
- A _bare_ status ping with no scope or invitation ("I started working on X") — that's noise. But a **scoped kickoff with an invitation** (specific area/branch + "ping me if you have context") **is** worth posting, once per session, for substantive work — see "What still requires a manual post" above.

## Resolution, trust, and state

Three things the copy-paste snippets above depend on, and none is self-evident from the JSON:

- **The registry is the enablement and trust boundary.** `repos.json` maps a
  stable repo id to a home-relative canonical checkout, expected GitHub remote,
  and main branch. Invalid, moved, unrelated, or remote-mismatched repositories
  fail closed before Huddle state or Git operations occur. Linked worktrees map
  back to the registered canonical clone through Git's common directory.

- **`config.json` is a rebuildable cache, not a source of truth.** It holds only `root_bead_id`, and it does not exist on a fresh clone. Session-start and `huddle_root_id` call `huddle_discover_root`, which finds the existing "Huddle coordination root" epic and **adopts** it (writing `config.json`) rather than forking a second root. If a raw `jq -r '.root_bead_id'` comes back null or the file is missing, that's a machine that hasn't adopted yet, not a broken huddle.
- **Root-notes `today_bead.id` is a hint, not the answer.** Today's daily resolves by `bd children <root>` title query; the notes pointer is a fast-path hint that gets verified via `bd show` before it's trusted. This is what fixed the PP-9lq5 dangling-pointer bug — a purged or renamed daily self-heals instead of lingering as a broken reference.

The channel is stored in the host repository's beads database, so every session
on that machine reads and writes one shared copy — the root bead, its `notes`
pointers, the daily and monthly beads, and all comments. There is no per-session
sync step.

Beads runs on **local embedded Dolt**, one database per repository. Where a repo
also configures a Dolt remote, `bd dolt push` / `bd dolt pull` carry the channel
off the machine; that is a property of the host repository's beads setup, not
something the huddle configures. An earlier design ran a shared `dolt sql-server`
so two machines could write the same database live. That is gone: it had two
divergent writers and produced an unmergeable conflict (the PP-1d51 collision).

`session-names.json` is **intentionally machine-local** in the agent-state
subtree, so a session never self-filters a post that another machine's session
wrote. Service cursors, locks, status, and logs live separately under
`${XDG_STATE_HOME:-$HOME/.local/state}/agents-huddle/service/<repo-id>/` and are
never agent-writable.
