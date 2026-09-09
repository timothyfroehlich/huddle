"""Contract fixtures for the thin Codex and Antigravity huddle adapters."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

HUDDLE_DIR = Path(__file__).parent.parent / "lib"


@pytest.mark.parametrize(
    "adapter",
    ["huddle-codex-adapter.cjs", "huddle-antigravity-adapter.cjs"],
)
def test_adapters_never_launch_git_maintenance(adapter: str) -> None:
    source = (HUDDLE_DIR / adapter).read_text()
    assert "huddle-main-watch" not in source
    assert "huddle-service.sh" not in source


@pytest.fixture()
def adapter_dir(tmp_path: Path) -> Path:
    """Copy adapters beside tiny script doubles, preserving their __dirname seam."""
    for name in ("huddle-codex-adapter.cjs", "huddle-antigravity-adapter.cjs"):
        shutil.copy2(HUDDLE_DIR / name, tmp_path / name)

    for name, reply in (
        ("huddle-session-start.sh", "session context"),
        ("huddle-poll.sh", "poll context"),
    ):
        (tmp_path / name).write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f'cat > "$HUDDLE_CAPTURE_DIR/{name}.json"\n'
            f"printf '%s\\n' '{reply}'\n"
        )
        (tmp_path / name).chmod(0o755)

    (tmp_path / "huddle-pr-announce.sh").write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        'cat > "$HUDDLE_CAPTURE_DIR/pr-announce.json"\n'
    )
    (tmp_path / "huddle-pr-announce.sh").chmod(0o755)
    return tmp_path


def run_adapter(
    adapter_dir: Path, adapter: str, *args: str, payload: dict[str, object]
) -> subprocess.CompletedProcess[str]:
    capture_dir = adapter_dir / "captured"
    capture_dir.mkdir(exist_ok=True)
    return subprocess.run(
        ["node", str(adapter_dir / adapter), *args],
        cwd=adapter_dir,
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
        env=os.environ | {"HUDDLE_CAPTURE_DIR": str(capture_dir)},
    )


def captured(adapter_dir: Path, name: str) -> dict[str, str]:
    return json.loads((adapter_dir / "captured" / f"{name}.json").read_text())


def test_codex_start_passes_its_real_contract_to_core(adapter_dir: Path) -> None:
    payload = {
        "session_id": "codex-session",
        "transcript_path": "/real/codex.jsonl",
        "cwd": str(adapter_dir),
    }
    result = run_adapter(
        adapter_dir, "huddle-codex-adapter.cjs", "start", payload=payload
    )

    assert json.loads(result.stdout) == {
        "continue": True,
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "session context\n",
        },
    }
    expected = {
        **payload,
        "hook_event_name": "SessionStart",
        "source": "startup",
        "harness": "Codex",
    }
    assert captured(adapter_dir, "huddle-session-start.sh") == expected
    assert not (adapter_dir / "captured" / "pr-announce.json").exists()


def test_codex_start_uses_thread_id_as_huddle_session_id(adapter_dir: Path) -> None:
    payload = {"threadId": "codex-thread", "cwd": str(adapter_dir)}
    result = run_adapter(
        adapter_dir, "huddle-codex-adapter.cjs", "start", payload=payload
    )

    assert json.loads(result.stdout) == {
        "continue": True,
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "session context\n",
        },
    }
    expected = {
        "session_id": "codex-thread",
        "transcript_path": "",
        "cwd": str(adapter_dir),
        "hook_event_name": "SessionStart",
        "source": "startup",
        "harness": "Codex",
    }
    assert captured(adapter_dir, "huddle-session-start.sh") == expected
    assert not (adapter_dir / "captured" / "pr-announce.json").exists()


def test_codex_post_tool_preserves_event_and_uses_poll(adapter_dir: Path) -> None:
    payload = {
        "sessionId": "codex-session",
        "transcriptPath": "/real/codex.jsonl",
        "cwd": str(adapter_dir),
    }
    result = run_adapter(
        adapter_dir, "huddle-codex-adapter.cjs", "post-tool", payload=payload
    )

    assert json.loads(result.stdout) == {
        "continue": True,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "poll context\n",
        },
    }
    expected = {
        "session_id": "codex-session",
        "transcript_path": "/real/codex.jsonl",
        "cwd": str(adapter_dir),
        "hook_event_name": "PostToolUse",
        "source": "startup",
        "harness": "Codex",
    }
    assert captured(adapter_dir, "huddle-poll.sh") == expected
    assert captured(adapter_dir, "pr-announce") == payload


def test_codex_manifest_hooks_point_at_the_stable_entrypoint() -> None:
    """Codex pins hook trust to a hash of each handler at a positional key.

    Editing a command string — or reordering matcher groups — silently revokes
    trust, and the hook then stops firing while still reporting as enabled. So
    every Codex hook must name `bin/huddle-hook`, never a lib script directly;
    all churn belongs inside that entrypoint, below the trust boundary.
    """
    manifest = Path(__file__).parent.parent / ".codex-plugin" / "plugin.json"
    hooks = json.loads(manifest.read_text())["hooks"]["hooks"]

    assert set(hooks) == {"SessionStart", "UserPromptSubmit", "PostToolUse"}
    for event, groups in hooks.items():
        for group in groups:
            for handler in group["hooks"]:
                assert "/bin/huddle-hook" in handler["command"], (
                    f"{event} hook must dispatch through bin/huddle-hook, "
                    f"not {handler['command']}"
                )


def test_antigravity_first_invocation_returns_ephemeral_session_context(
    adapter_dir: Path,
) -> None:
    payload = {
        "conversationId": "anti-session",
        "transcriptPath": "/real/anti.jsonl",
        "workspacePaths": [str(adapter_dir)],
        "invocationNum": 0,
    }
    result = run_adapter(
        adapter_dir, "huddle-antigravity-adapter.cjs", "before-agent", payload=payload
    )

    assert json.loads(result.stdout) == {
        "injectSteps": [{"ephemeralMessage": "session context"}]
    }
    expected = {
        "session_id": "anti-session",
        "transcript_path": "/real/anti.jsonl",
        "cwd": str(adapter_dir),
        "hook_event_name": "SessionStart",
        "source": "startup",
    }
    assert captured(adapter_dir, "huddle-session-start.sh") == expected
    assert not (adapter_dir / "captured" / "pr-announce.json").exists()


def test_antigravity_later_invocation_and_post_tool_use_the_right_events(
    adapter_dir: Path,
) -> None:
    later = {
        "conversationId": "anti-session",
        "transcriptPath": "/real/anti.jsonl",
        "workspacePaths": [str(adapter_dir)],
        "invocationNum": 2,
    }
    result = run_adapter(
        adapter_dir, "huddle-antigravity-adapter.cjs", "before-agent", payload=later
    )

    assert json.loads(result.stdout) == {
        "injectSteps": [{"ephemeralMessage": "poll context"}]
    }
    expected_poll = {
        "session_id": "anti-session",
        "transcript_path": "/real/anti.jsonl",
        "cwd": str(adapter_dir),
        "hook_event_name": "UserPromptSubmit",
        "source": "startup",
    }
    assert captured(adapter_dir, "huddle-poll.sh") == expected_poll

    result = run_adapter(
        adapter_dir, "huddle-antigravity-adapter.cjs", "post-tool", payload=later
    )
    assert json.loads(result.stdout) == {}
    assert captured(adapter_dir, "pr-announce") == {
        **later,
        "tool_name": "",
        "tool_input": {},
        "tool_response": {},
    }
