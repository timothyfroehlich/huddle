"""Trusted repository resolution and legacy-state migration tests."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

LIB = Path(__file__).parent.parent / "lib" / "huddle-lib.sh"


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, text=True, capture_output=True
    ).stdout.strip()


def write_registry(
    home: Path,
    checkout: str,
    *,
    github_remote: str = "example/huddle-test",
    repo_id: str = "pinpoint",
) -> Path:
    config = home / "repos.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "repositories": [
                    {
                        "id": repo_id,
                        "checkout": checkout,
                        "github_remote": github_remote,
                        "main_branch": "main",
                    }
                ],
            }
        )
    )
    return config


def make_repo(home: Path, relative: str = "Code/PinPoint") -> Path:
    repo = home / relative
    repo.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=repo)
    git("config", "user.email", "test@example.com", cwd=repo)
    git("config", "user.name", "Test", cwd=repo)
    (repo / "tracked").write_text("one\n")
    git("add", "tracked", cwd=repo)
    git("commit", "-q", "-m", "initial", cwd=repo)
    git("remote", "add", "origin", "git@github.com:example/huddle-test.git", cwd=repo)
    return repo


def resolver_env(home: Path, config: Path, state: Path) -> dict[str, str]:
    return os.environ | {
        "HOME": str(home),
        "HUDDLE_CONFIG_FILE": str(config),
        "HUDDLE_AGENT_STATE_ROOT": str(state),
    }


def resolve(cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f"source '{LIB}'; huddle_state_dir"],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
    )


def test_canonical_checkout_resolves_to_repo_id_state(tmp_path: Path) -> None:
    home = tmp_path / "home"
    repo = make_repo(home)
    config = write_registry(home, "Code/PinPoint")
    state = tmp_path / "state"
    result = resolve(repo, resolver_env(home, config, state))
    assert result.returncode == 0
    assert result.stdout == str(state / "pinpoint")


def test_linked_worktree_resolves_to_canonical_clone(tmp_path: Path) -> None:
    home = tmp_path / "home"
    repo = make_repo(home)
    linked = tmp_path / "linked worktree"
    git("worktree", "add", "-q", "-b", "feature", str(linked), cwd=repo)
    config = write_registry(home, "Code/PinPoint")
    state = tmp_path / "state"
    result = resolve(linked, resolver_env(home, config, state))
    assert result.returncode == 0
    assert result.stdout == str(state / "pinpoint")


def test_unrelated_repository_is_silent(tmp_path: Path) -> None:
    home = tmp_path / "home"
    make_repo(home)
    unrelated = tmp_path / "unrelated"
    unrelated.mkdir()
    git("init", "-q", cwd=unrelated)
    config = write_registry(home, "Code/PinPoint")
    result = resolve(unrelated, resolver_env(home, config, tmp_path / "state"))
    assert result.returncode != 0
    assert result.stdout == ""


@pytest.mark.parametrize(
    "checkout", ["../PinPoint", "/tmp/PinPoint", "Code/./PinPoint"]
)
def test_invalid_registry_checkout_fails_closed(tmp_path: Path, checkout: str) -> None:
    home = tmp_path / "home"
    repo = make_repo(home)
    config = write_registry(home, checkout)
    result = resolve(repo, resolver_env(home, config, tmp_path / "state"))
    assert result.returncode != 0
    assert result.stdout == ""


def test_remote_mismatch_fails_closed(tmp_path: Path) -> None:
    home = tmp_path / "home"
    repo = make_repo(home)
    config = write_registry(home, "Code/PinPoint", github_remote="example/other")
    result = resolve(repo, resolver_env(home, config, tmp_path / "state"))
    assert result.returncode != 0


def test_spaces_in_registered_checkout_are_supported(tmp_path: Path) -> None:
    home = tmp_path / "home"
    repo = make_repo(home, "Code/Pin Point")
    config = write_registry(home, "Code/Pin Point")
    state = tmp_path / "state with spaces"
    result = resolve(repo, resolver_env(home, config, state))
    assert result.returncode == 0
    assert result.stdout == str(state / "pinpoint")


def test_legacy_state_is_migrated_atomically_once(tmp_path: Path) -> None:
    home = tmp_path / "home"
    repo = make_repo(home)
    legacy = repo / ".agents" / "huddle"
    legacy.mkdir(parents=True)
    (legacy / "config.json").write_text('{"root_bead_id":"PP-root"}\n')
    (legacy / "session-names.json").write_text('{"sid":"Codex-Test"}\n')
    (legacy / "last-seen-abc").write_text("2026-08-24T00:00:00Z")
    (legacy / "nudged-sid").write_text("123")
    (legacy / "rotation.lock").write_text("stale")
    (legacy / "pull.lock").write_text("stale")
    (legacy / "unknown.txt").write_text("do not copy")
    config = write_registry(home, "Code/PinPoint")
    state = tmp_path / "state"
    env = resolver_env(home, config, state)

    processes = [
        subprocess.Popen(
            ["bash", "-c", f"source '{LIB}'; huddle_state_dir"],
            cwd=repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        for _ in range(8)
    ]
    for process in processes:
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        assert stdout == str(state / "pinpoint")

    target = state / "pinpoint"
    assert json.loads((target / "config.json").read_text()) == {
        "root_bead_id": "PP-root"
    }
    assert json.loads((target / "session-names.json").read_text()) == {
        "sid": "Codex-Test"
    }
    assert (target / "last-seen-abc").read_text() == "2026-08-24T00:00:00Z"
    assert (target / "nudged-sid").read_text() == "123"
    assert not (target / "rotation.lock").exists()
    assert not (target / "pull.lock").exists()
    assert not (target / "unknown.txt").exists()
    assert not list(target.glob(".migrate-*"))
    assert (target / ".legacy-migration-complete").is_file()

    (legacy / "config.json").write_text('{"root_bead_id":"PP-changed"}\n')
    assert resolve(repo, env).returncode == 0
    assert json.loads((target / "config.json").read_text()) == {
        "root_bead_id": "PP-root"
    }
    assert json.loads((legacy / "config.json").read_text()) == {
        "root_bead_id": "PP-changed"
    }


def test_legacy_worktree_poll_marker_is_migrated_without_overwrite(
    tmp_path: Path,
) -> None:
    worktree = tmp_path / "linked worktree"
    legacy = worktree / ".agents" / ".huddle-last-poll"
    target = tmp_path / "state" / "pinpoint" / "last-poll-worktree"
    legacy.parent.mkdir(parents=True)
    legacy.write_text("123\n")

    command = (
        f"source '{LIB}'; huddle_migrate_legacy_poll_marker '{worktree}' '{target}'"
    )
    first = subprocess.run(["bash", "-c", command], text=True, capture_output=True)
    assert first.returncode == 0, first.stderr
    assert target.read_text() == "123\n"
    assert legacy.read_text() == "123\n"

    target.write_text("456\n")
    second = subprocess.run(["bash", "-c", command], text=True, capture_output=True)
    assert second.returncode == 0, second.stderr
    assert target.read_text() == "456\n"
