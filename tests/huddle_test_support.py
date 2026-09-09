"""Shared registry setup for Huddle subprocess tests."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


def configure_huddle_repo(repo: Path) -> None:
    """Register a temporary checkout while keeping legacy fixture paths usable."""
    subprocess.run(
        ["git", "remote", "add", "origin", "git@github.com:example/huddle-test.git"],
        cwd=repo,
        check=True,
    )
    (repo / ".huddle-test-repos.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "repositories": [
                    {
                        "id": "huddle",
                        "checkout": repo.name,
                        "github_remote": "example/huddle-test",
                        "main_branch": "main",
                    }
                ],
            }
        )
    )


def huddle_test_env(repo: Path) -> dict[str, str]:
    """Return resolver overrides for a configured temporary checkout."""
    return {
        "HOME": str(repo.parent),
        "HUDDLE_CONFIG_FILE": str(repo / ".huddle-test-repos.json"),
        "HUDDLE_AGENT_STATE_ROOT": str(repo / ".agents"),
    }
