"""Huddle updater/leader user-service integration tests."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

SERVICE = Path(__file__).parent.parent / "lib" / "huddle-service.sh"
REAL_GIT = shutil.which("git")
REAL_MV = shutil.which("mv")
assert REAL_GIT is not None
assert REAL_MV is not None


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(
        [REAL_GIT, *args], cwd=cwd, check=True, text=True, capture_output=True
    ).stdout.strip()


def commit(repo: Path, subject: str, content: str) -> str:
    (repo / "file").write_text(content)
    git("add", "file", cwd=repo)
    git("commit", "-q", "-m", subject, cwd=repo)
    return git("rev-parse", "HEAD", cwd=repo)


@pytest.fixture()
def service_world(tmp_path: Path) -> dict[str, Path | dict[str, str]]:
    home = tmp_path / "home"
    root = home / "Code" / "PinPoint"
    origin = tmp_path / "origin.git"
    seed = tmp_path / "seed"
    state = tmp_path / "state"
    agent_state = tmp_path / "agent-state"
    bin_dir = tmp_path / "bin"
    calls = tmp_path / "bd-calls"
    comments = tmp_path / "comments.json"
    home.mkdir()
    seed.mkdir()
    bin_dir.mkdir()
    comments.write_text("[]")

    git("init", "--bare", "-q", "-b", "main", str(origin))
    git("init", "-q", "-b", "main", cwd=seed)
    git("config", "user.email", "test@example.com", cwd=seed)
    git("config", "user.name", "Test", cwd=seed)
    first = commit(seed, "initial", "one\n")
    git("remote", "add", "origin", str(origin), cwd=seed)
    git("push", "-q", "origin", "main", cwd=seed)
    second = commit(seed, "feat: historical merge (#42)", "two\n")
    git("push", "-q", "origin", "main", cwd=seed)
    root.parent.mkdir(parents=True)
    git("clone", "-q", str(origin), str(root))
    git("reset", "--hard", "-q", first, cwd=root)
    git(
        "remote",
        "set-url",
        "origin",
        "git@github.com:example/huddle-test.git",
        cwd=root,
    )

    legacy = root / ".agents" / "huddle"
    legacy.mkdir(parents=True)
    (legacy / "config.json").write_text('{"root_bead_id":"PP-root"}\n')
    beads = root / ".beads"
    beads.mkdir()
    (beads / "metadata.json").write_text(
        json.dumps({"database": "dolt", "backend": "dolt", "dolt_mode": "server"})
    )
    (root / ".git" / "info" / "exclude").write_text(".agents/\n.beads/\n")
    config = home / "repos.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "repositories": [
                    {
                        "id": "pinpoint",
                        "checkout": "Code/PinPoint",
                        "github_remote": "example/huddle-test",
                        "main_branch": "main",
                    }
                ],
            }
        )
    )

    git_stub = bin_dir / "git"
    git_stub.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        'if [[ "$*" == *" fetch --quiet origin main" ]]; then\n'
        '  [[ "${FAIL_FETCH:-0}" == 1 ]] && exit 1\n'
        '  checkout="$2"\n'
        '  exec "$REAL_GIT" -C "$checkout" fetch --quiet "$TEST_ORIGIN" '
        + "'+main:refs/remotes/origin/main'\n"
        "fi\n"
        'exec "$REAL_GIT" "$@"\n'
    )
    git_stub.chmod(0o755)

    mv_stub = bin_dir / "mv"
    mv_stub.write_text(
        "#!/usr/bin/env bash\n"
        "set -u\n"
        'destination=""\n'
        'for argument in "$@"; do destination="$argument"; done\n'
        'if [[ -n "${FAIL_STATUS_PATH:-}" && "$destination" == "$FAIL_STATUS_PATH" ]]; then\n'
        "  exit 1\n"
        "fi\n"
        'exec "$REAL_MV" "$@"\n'
    )
    mv_stub.chmod(0o755)

    bd_stub = bin_dir / "bd"
    bd_stub.write_text(
        "#!/usr/bin/env bash\n"
        "set -u\n"
        '[[ "$PWD" == "$EXPECTED_BD_CWD" ]] || exit 97\n'
        "today=$(date +%F)\n"
        'case "$1" in\n'
        "  show)\n"
        '    case "$2" in\n'
        '      PP-root) printf \'%s\\n\' \'[{"notes":"{\\"today_bead\\":{\\"id\\":\\"PP-today\\"}}"}]\' ;;\n'
        '      PP-today) printf \'[{"id":"PP-today","title":"Huddle daily %s","status":"open"}]\\n\' "$today" ;;\n'
        "    esac ;;\n"
        "  children) printf '[]\\n' ;;\n"
        '  dolt) printf \'%s\\n\' "$*" >> "$BD_SYNC_CALLS" ;;\n'
        "  comments)\n"
        '    if [[ "${2:-}" == add ]]; then\n'
        '      [[ "${BD_FAIL_POST:-0}" == 1 ]] && exit 1\n'
        '      printf \'%s\\n\' "$4" >> "$BD_CALLS"\n'
        "    else\n"
        '      cat "$BD_COMMENTS"\n'
        "    fi ;;\n"
        "esac\n"
    )
    bd_stub.chmod(0o755)

    env = os.environ | {
        "HOME": str(home),
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "REAL_GIT": REAL_GIT,
        "REAL_MV": REAL_MV,
        "TEST_ORIGIN": str(origin),
        "EXPECTED_BD_CWD": str(root),
        "BD_CALLS": str(calls),
        "BD_SYNC_CALLS": str(tmp_path / "bd-sync-calls"),
        "BD_COMMENTS": str(comments),
        "HUDDLE_CONFIG_FILE": str(config),
        "HUDDLE_AGENT_STATE_ROOT": str(agent_state),
        "HUDDLE_SERVICE_STATE_ROOT": str(state),
    }
    return {
        "home": home,
        "root": root,
        "origin": origin,
        "seed": seed,
        "state": state,
        "calls": calls,
        "sync_calls": tmp_path / "bd-sync-calls",
        "comments": comments,
        "env": env,
        "first": Path(first),
        "second": Path(second),
    }


def run_service(
    world: dict[str, Path | dict[str, str]],
    role: str,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = dict(world["env"])
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(SERVICE), "run", "--role", role],
        env=env,
        text=True,
        capture_output=True,
    )


def push_merge(
    world: dict[str, Path | dict[str, str]], number: int, content: str
) -> str:
    seed = Path(world["seed"])
    sha = commit(seed, f"fix: merge {number} (#{number})", content)
    git("push", "-q", "origin", "main", cwd=seed)
    return sha


def test_first_leader_run_baselines_without_replay_and_fast_forwards(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    result = run_service(service_world, "leader")
    assert result.returncode == 0, result.stderr
    root = Path(service_world["root"])
    second = str(service_world["second"])
    assert git("rev-parse", "HEAD", cwd=root) == second
    state = Path(service_world["state"]) / "pinpoint"
    assert (state / "announcement-cursor").read_text().strip() == second
    assert not Path(service_world["calls"]).exists()
    status = json.loads((state / "status.json").read_text())
    assert status["healthy"] is True
    assert status["outcome"] == "fast-forwarded"


@pytest.mark.parametrize(
    ("setup", "outcome"),
    [("dirty", "skipped-dirty"), ("off-main", "skipped-off-main")],
)
def test_dirty_or_off_main_root_is_not_updated(
    service_world: dict[str, Path | dict[str, str]], setup: str, outcome: str
) -> None:
    root = Path(service_world["root"])
    first = git("rev-parse", "HEAD", cwd=root)
    if setup == "dirty":
        (root / "dirty").write_text("keep\n")
    else:
        git("checkout", "-q", "-b", "feature", cwd=root)
    result = run_service(service_world, "updater")
    assert result.returncode == 0, result.stderr
    assert git("rev-parse", "HEAD", cwd=root) == first
    status = json.loads(
        (Path(service_world["state"]) / "pinpoint" / "status.json").read_text()
    )
    assert status["outcome"] == outcome


def test_diverged_main_root_is_not_updated(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    root = Path(service_world["root"])
    git("config", "user.email", "test@example.com", cwd=root)
    git("config", "user.name", "Test", cwd=root)
    local_head = commit(root, "local divergence", "local\n")

    result = run_service(service_world, "updater")

    assert result.returncode == 0, result.stderr
    assert git("rev-parse", "HEAD", cwd=root) == local_head
    status = json.loads(
        (Path(service_world["state"]) / "pinpoint" / "status.json").read_text()
    )
    assert status["outcome"] == "skipped-diverged"


def test_leader_announces_each_new_merge_once(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    assert run_service(service_world, "leader").returncode == 0
    push_merge(service_world, 76, "three\n")
    sha = push_merge(service_world, 77, "four\n")
    assert run_service(service_world, "leader").returncode == 0
    calls = Path(service_world["calls"])
    assert calls.read_text().splitlines() == [
        "Merged PR #76: fix: merge 76 —huddle-auto",
        "Merged PR #77: fix: merge 77 —huddle-auto",
    ]
    assert run_service(service_world, "leader").returncode == 0
    assert calls.read_text().splitlines() == [
        "Merged PR #76: fix: merge 76 —huddle-auto",
        "Merged PR #77: fix: merge 77 —huddle-auto",
    ]
    cursor = Path(service_world["state"]) / "pinpoint" / "announcement-cursor"
    assert cursor.read_text().strip() == sha


def test_failed_post_retains_cursor_for_retry(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    assert run_service(service_world, "leader").returncode == 0
    cursor = Path(service_world["state"]) / "pinpoint" / "announcement-cursor"
    baseline = cursor.read_text()
    sha = push_merge(service_world, 88, "four\n")
    failed = run_service(service_world, "leader", {"BD_FAIL_POST": "1"})
    assert failed.returncode != 0
    assert cursor.read_text() == baseline
    assert run_service(service_world, "leader").returncode == 0
    assert "Merged PR #88" in Path(service_world["calls"]).read_text()
    assert cursor.read_text().strip() == sha


def test_existing_announcement_is_deduplicated(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    assert run_service(service_world, "leader").returncode == 0
    sha = push_merge(service_world, 99, "five\n")
    Path(service_world["comments"]).write_text(
        json.dumps([{"text": "Merged PR #99: already there —huddle-auto"}])
    )
    assert run_service(service_world, "leader").returncode == 0
    assert not Path(service_world["calls"]).exists()
    cursor = Path(service_world["state"]) / "pinpoint" / "announcement-cursor"
    assert cursor.read_text().strip() == sha


def test_force_push_resets_cursor_without_replay(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    assert run_service(service_world, "leader").returncode == 0
    seed = Path(service_world["seed"])
    git("checkout", "-q", "--orphan", "replacement", cwd=seed)
    git("rm", "-q", "-f", "file", cwd=seed)
    replacement = commit(seed, "fix: rewritten merge (#123)", "replacement\n")
    git("push", "-q", "--force", "origin", "HEAD:main", cwd=seed)
    assert run_service(service_world, "leader").returncode == 0
    assert not Path(service_world["calls"]).exists()
    cursor = Path(service_world["state"]) / "pinpoint" / "announcement-cursor"
    assert cursor.read_text().strip() == replacement


def test_updater_never_posts_announcements(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    assert run_service(service_world, "updater").returncode == 0
    push_merge(service_world, 111, "six\n")
    assert run_service(service_world, "updater").returncode == 0
    assert not Path(service_world["calls"]).exists()
    assert not (
        Path(service_world["state"]) / "pinpoint" / "announcement-cursor"
    ).exists()


def test_successful_run_fails_when_status_cannot_be_persisted(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    status_path = Path(service_world["state"]) / "pinpoint" / "status.json"
    result = run_service(
        service_world, "updater", {"FAIL_STATUS_PATH": str(status_path)}
    )

    assert result.returncode != 0
    log = status_path.parent / "service.log"
    assert "could not persist successful service status" in log.read_text()
    assert not (status_path.parent / "run.lock").exists()


def test_successful_run_fails_when_registry_status_cannot_be_persisted(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    registry_status = Path(service_world["state"]) / "_registry" / "status.json"
    result = run_service(
        service_world, "updater", {"FAIL_STATUS_PATH": str(registry_status)}
    )

    assert result.returncode != 0
    log = registry_status.parent / "service.log"
    assert "could not persist successful registry status" in log.read_text()
    assert not (Path(service_world["state"]) / "pinpoint" / "status.json").exists()


def test_status_reports_healthy_service_state(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    assert run_service(service_world, "updater").returncode == 0
    result = subprocess.run(
        ["bash", str(SERVICE), "status"],
        env=dict(service_world["env"]),
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0
    assert "registry: healthy" in result.stdout
    assert "pinpoint: healthy" in result.stdout


def test_status_rejects_stale_service_state(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    assert run_service(service_world, "updater").returncode == 0
    status_path = Path(service_world["state"]) / "pinpoint" / "status.json"
    status = json.loads(status_path.read_text())
    status["checked_at_epoch"] = 1
    status_path.write_text(json.dumps(status))

    result = subprocess.run(
        ["bash", str(SERVICE), "status"],
        env=dict(service_world["env"]),
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "pinpoint: stale" in result.stdout


@pytest.mark.parametrize(
    ("healthy", "checked_at_epoch", "expected"),
    [(False, None, "registry: unhealthy"), (True, 1, "registry: stale")],
)
def test_status_rejects_unhealthy_or_stale_registry_state(
    service_world: dict[str, Path | dict[str, str]],
    healthy: bool,
    checked_at_epoch: int | None,
    expected: str,
) -> None:
    assert run_service(service_world, "updater").returncode == 0
    status_path = Path(service_world["state"]) / "_registry" / "status.json"
    status = json.loads(status_path.read_text())
    status["healthy"] = healthy
    if checked_at_epoch is not None:
        status["checked_at_epoch"] = checked_at_epoch
    status_path.write_text(json.dumps(status))

    result = subprocess.run(
        ["bash", str(SERVICE), "status"],
        env=dict(service_world["env"]),
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert expected in result.stdout


def test_status_rejects_invalid_current_registry(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    assert run_service(service_world, "updater").returncode == 0
    config = Path(dict(service_world["env"])["HUDDLE_CONFIG_FILE"])
    config.write_text('{"schema_version": 1, "repositories": []}\n')

    result = subprocess.run(
        ["bash", str(SERVICE), "status"],
        env=dict(service_world["env"]),
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "registry: invalid current configuration" in result.stdout


def _set_dolt_mode(world: dict[str, Path | dict[str, str]], mode: str) -> None:
    (Path(world["root"]) / ".beads" / "metadata.json").write_text(
        json.dumps({"database": "dolt", "backend": "dolt", "dolt_mode": mode})
    )


@pytest.mark.parametrize("role", ["leader", "updater"])
def test_service_pushes_then_pulls_the_dolt_remote_in_embedded_mode(
    service_world: dict[str, Path | dict[str, str]], role: str
) -> None:
    _set_dolt_mode(service_world, "embedded")

    result = run_service(service_world, role)

    assert result.returncode == 0, result.stderr
    calls = Path(service_world["sync_calls"]).read_text().splitlines()
    assert calls == ["dolt push --quiet", "dolt pull --quiet"]


def test_service_sync_is_throttled_across_runs(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    _set_dolt_mode(service_world, "embedded")

    assert run_service(service_world, "leader").returncode == 0
    assert run_service(service_world, "leader").returncode == 0

    calls = Path(service_world["sync_calls"]).read_text().splitlines()
    assert calls == ["dolt push --quiet", "dolt pull --quiet"]


def test_service_skips_dolt_sync_in_server_mode(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    result = run_service(service_world, "leader")

    assert result.returncode == 0, result.stderr
    assert not Path(service_world["sync_calls"]).exists()


def test_service_syncs_dolt_even_when_git_fetch_fails(
    service_world: dict[str, Path | dict[str, str]],
) -> None:
    _set_dolt_mode(service_world, "embedded")

    result = run_service(service_world, "leader", {"FAIL_FETCH": "1"})

    assert result.returncode != 0
    calls = Path(service_world["sync_calls"]).read_text().splitlines()
    assert calls == ["dolt push --quiet", "dolt pull --quiet"]
