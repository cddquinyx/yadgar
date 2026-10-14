"""Per-directory hook opt-out — the ``.yadgar-disabled`` marker.

A file named ``.yadgar-disabled`` in the session's working directory, or in
any ancestor of it, switches every host-side memory/context hook off for that
tree: the hook exits silently, prints nothing, and never contacts the daemon
or writes a record. It is the whole-Yadgar counterpart of ADR-0162's old
``.code-graph-disabled`` marker, and it is a FILE rather than a runtime-config
row (ADR-0163) on purpose — the hooks must decide before any daemon round
trip, and the opt-out exists precisely so the daemon never sees the tree.

Why this exists: Claude Code's only alternative is ``disableAllHooks`` in the
project's ``.claude/settings.local.json``, which also switches off the status
line and every non-yadgar hook. A marker the hooks honour themselves lets a
project keep its own hooks and status line while staying out of the memory
store.

Deliberately NOT honoured by ``pretooluse-router.py``: its guards exist to
stop the agent bypassing hard rules, and a marker the agent can create must
not be able to switch them off (the same reasoning as the router's G5
hook-config-tamper guard).

Stdlib-only apart from ``observe`` — hooks are short-lived host processes.
"""

from __future__ import annotations

import os
from pathlib import Path

from yadgar._shared.observability.observe import observe

MARKER = ".yadgar-disabled"


@observe(tier="hot")
def hooks_disabled(cwd: str | None = None) -> bool:
    """True iff *cwd* (or an ancestor) carries the ``.yadgar-disabled`` marker.

    *cwd* is the ``cwd`` field of the hook payload. When it is empty the
    ``CLAUDE_PROJECT_DIR`` env var (set by Claude Code for every hook) is
    used, then the process cwd. A directory that cannot be resolved is
    treated as NOT opted out — the marker is an explicit choice, never a
    default.
    """
    start = cwd or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        path = Path(start).expanduser().resolve()
    # ValueError: a NUL byte in the path.
    except (OSError, RuntimeError, ValueError):  # fmt: skip
        return False
    try:
        return any((d / MARKER).exists() for d in (path, *path.parents))
    except OSError:
        return False
