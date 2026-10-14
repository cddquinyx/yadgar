"""Per-directory hook opt-out — the ``.yadgar-disabled`` marker.

A marker file in the session cwd (or any ancestor) makes every memory/context
hook exit silently before contacting the daemon or writing a record. Covers:

- ``hooks_disabled``: cwd, ancestor, absent, ``CLAUDE_PROJECT_DIR`` fallback,
  unresolvable cwd.
- ``dispatch`` (the six ``hook_runner.py`` / ``yadgar hook`` events): handler
  skipped when opted out; stdin handed back intact when not.
- the standalone scripts: stop checkpoint, session-end capture, FileChanged,
  InstructionsLoaded, SubagentStart.
- the PreToolUse router's guards stay LIVE under the marker (deliberate — a
  marker the agent can create must not switch the guards off).
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

import pytest

import yadgar.core.cli.hook as hr
from yadgar.core.hooks._optout import MARKER, hooks_disabled

_HOOKS_DIR = Path(__file__).parent.parent.parent / "core" / "hooks"


def _load_script(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(f"_optout_test_{name}", _HOOKS_DIR / name)
    assert spec is not None and spec.loader is not None, name
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def opted_out(tmp_path: Path) -> Path:
    """A project tree whose root carries the marker; returns a nested cwd."""
    (tmp_path / MARKER).write_text("")
    nested = tmp_path / "src" / "deep"
    nested.mkdir(parents=True)
    return nested


@pytest.fixture
def opted_in(tmp_path: Path) -> Path:
    nested = tmp_path / "src"
    nested.mkdir()
    return nested


# ── hooks_disabled ───────────────────────────────────────────────────────────


def test_marker_in_cwd(tmp_path):
    (tmp_path / MARKER).write_text("")
    assert hooks_disabled(str(tmp_path)) is True


def test_marker_in_ancestor(opted_out):
    assert hooks_disabled(str(opted_out)) is True


def test_no_marker(opted_in):
    assert hooks_disabled(str(opted_in)) is False


def test_empty_cwd_falls_back_to_claude_project_dir(opted_out, monkeypatch):
    monkeypatch.setenv("CLAUDE_PROJECT_DIR", str(opted_out))
    assert hooks_disabled("") is True
    assert hooks_disabled(None) is True


def test_empty_cwd_falls_back_to_process_cwd(opted_out, monkeypatch):
    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)
    monkeypatch.chdir(opted_out)
    assert hooks_disabled("") is True


def test_unresolvable_cwd_is_not_opted_out(tmp_path):
    assert hooks_disabled(str(tmp_path / "does" / "not" / "exist")) is False
    assert hooks_disabled("\0bad") is False


# ── dispatch (hook_runner.py / `yadgar hook <event>`) ────────────────────────


def _dispatch_with_payload(monkeypatch, payload: dict, event: str = "post-tool-capture"):
    calls: list[dict] = []

    def fake_handler():
        calls.append(json.load(sys.stdin))

    monkeypatch.setitem(hr._HOOKS, event, fake_handler)
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(payload)))
    rc = hr.dispatch(event)
    return rc, calls


def test_dispatch_skips_handler_when_opted_out(monkeypatch, opted_out, capsys):
    rc, calls = _dispatch_with_payload(monkeypatch, {"cwd": str(opted_out), "tool_name": "Bash"})
    assert rc == 0
    assert calls == []
    assert capsys.readouterr().out == ""


def test_dispatch_hands_stdin_back_intact_when_opted_in(monkeypatch, opted_in):
    payload = {"cwd": str(opted_in), "tool_name": "Bash", "session_id": "s1"}
    rc, calls = _dispatch_with_payload(monkeypatch, payload)
    assert rc == 0
    assert calls == [payload]


def test_dispatch_leaves_unreadable_stdin_to_the_handler(monkeypatch):
    seen: list[str] = []

    class _Broken:
        def read(self):
            raise OSError("closed")

    def fake_handler():
        seen.append(type(sys.stdin).__name__)

    monkeypatch.setitem(hr._HOOKS, "post-tool-capture", fake_handler)
    monkeypatch.setattr(sys, "stdin", _Broken())
    assert hr.dispatch("post-tool-capture") == 0
    assert seen == ["_Broken"]


def test_dispatch_opt_out_covers_every_event(monkeypatch, opted_out):
    for event in list(hr._HOOKS):
        rc, calls = _dispatch_with_payload(monkeypatch, {"cwd": str(opted_out)}, event=event)
        assert (rc, calls) == (0, []), event


# ── standalone scripts ───────────────────────────────────────────────────────


def test_stop_checkpoint_allows_stop_without_touching_transcript(opted_out, tmp_path):
    mod = _load_script("stop-memory-checkpoint.py")
    transcript = tmp_path / "transcript.jsonl"
    transcript.write_text("not json — reading this would raise\n")
    payload = {"cwd": str(opted_out), "transcript_path": str(transcript), "session_id": "s"}
    captured: list[str] = []
    with (
        patch.object(mod.sys, "stdin", io.StringIO(json.dumps(payload))),
        patch("builtins.print", side_effect=lambda s="": captured.append(s)),
        patch.object(mod, "get_settings", side_effect=AssertionError("daemon settings read")),
    ):
        mod.main()
    assert captured == ["{}"]


def test_session_end_capture_writes_no_sentinel(opted_out, tmp_path):
    sentinels = tmp_path / "sentinels"
    env = {
        **os.environ,
        "YADGAR_SESSION_ENDS_DIR": str(sentinels),
        "YADGAR_DATA_DIR": str(tmp_path / "data"),
    }
    payload = {"cwd": str(opted_out), "transcript_path": "/nonexistent", "end_reason": "exit"}
    proc = subprocess.run(
        [sys.executable, str(_HOOKS_DIR / "session-end-capture.py")],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == ""
    assert not sentinels.exists()


@pytest.mark.parametrize(
    ("module", "target", "payload"),
    [
        (
            "yadgar.core.hooks.file_changed",
            "_post_file_changed",
            {"file_path": "~/.claude/team_inbox/x/y.jsonl", "file_action": "modified"},
        ),
        (
            "yadgar.core.hooks.instructions_loaded",
            "_call_daemon",
            {"load_reason": "session_start", "file_path": "/p/CLAUDE.md"},
        ),
        (
            "yadgar.core.hooks.subagent_start",
            "_call_daemon",
            {"agent_type": "general-purpose", "description": "x"},
        ),
    ],
)
def test_module_hooks_never_call_daemon_when_opted_out(
    module, target, payload, opted_out, monkeypatch
):
    mod = importlib.import_module(module)
    monkeypatch.setattr(mod, target, lambda *a, **k: pytest.fail(f"{target} called"))
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps({**payload, "cwd": str(opted_out)})))
    mod.main()


@pytest.mark.parametrize(
    "script", ["file-changed.py", "instructions-loaded.py", "subagent-start.py"]
)
def test_shim_fallbacks_carry_the_gate(script):
    """The inline fallbacks (yadgar unimportable) honour the marker too."""
    text = (_HOOKS_DIR / script).read_text()
    assert "def _hooks_disabled(cwd)" in text
    assert '".yadgar-disabled"' in text


# ── PreToolUse router: guards stay live under the marker ─────────────────────


def test_router_guards_ignore_the_marker(opted_out):
    mod = _load_script("pretooluse-router.py")
    payload = {
        "tool_name": "Bash",
        "cwd": str(opted_out),
        "tool_input": {"command": "git commit --no-verify -m x"},
    }
    captured: list[str] = []
    with (
        patch.object(mod.sys, "stdin", io.StringIO(json.dumps(payload))),
        patch("builtins.print", side_effect=lambda s: captured.append(s)),
    ):
        mod.main()
    out = json.loads(captured[-1])
    assert out.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"
