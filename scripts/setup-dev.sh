#!/usr/bin/env bash
# Yadgar local dev environment bootstrap.
#
# Creates a Python 3.14 venv at ./.venv, installs yadgar in editable mode
# with the [test,ml,dev] extras, and wires up the pre-commit hook.
#
# Usage:
#   ./scripts/setup-dev.sh
#   ./scripts/setup-dev.sh --recreate   # nuke ./.venv and start fresh
#
# Requirements:
#   - uv on PATH (preferred — brings its own CPython 3.14; the nix dev shell
#     provides it), or
#   - python3.14 on PATH. On NixOS do NOT use the nix python314 for this — see
#     INTERPRETER CHOICE below; use uv, or set PYTHON= knowingly.
#   - git working tree with pyproject.toml
#
# INTERPRETER CHOICE — why uv-managed CPython is preferred, not just convenient:
# on NixOS the venv must NOT be built on the nix python. nix-ld, which is what
# makes ordinary manylinux wheels importable there, only intercepts NON-nix
# binaries, so a nix interpreter can never dlopen libstdc++ and `import numpy`
# / `import torch` fails in anything that runs .venv/bin/python3 without the
# dev shell in scope — the Claude Code hooks, systemd units, plain cron. A
# uv-downloaded CPython is an ordinary binary, so it works everywhere with no
# LD_LIBRARY_PATH and no interpreter wrapper. Harmless on other hosts: same
# CPython, just not the distro's copy. Set PYTHON=... to force a specific
# interpreter and take the stdlib-venv + pip path instead.
#
# The policy is repo config, not this script: .python-version pins 3.14 and
# pyproject.toml's [tool.uv] sets python-preference = "only-managed", so
# `uv venv` / `uv run` refuse to fall back to a system or nix interpreter.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/.venv"
PYVER="3.14"

recreate=0
for arg in "$@"; do
  case "$arg" in
    --recreate) recreate=1 ;;
    -h|--help)
      # Print the header comment block: line 2 up to the first blank line, so
      # the range cannot drift when the header grows.
      sed -n '2,/^$/{/^$/q;p}' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

# Pick the interpreter route: explicit PYTHON= override, else uv, else a
# python3.14 already on PATH (see INTERPRETER CHOICE in the header).
if [ -n "${PYTHON:-}" ]; then
  route="pip"
  PY="$PYTHON"
elif command -v uv >/dev/null 2>&1; then
  route="uv"
  PY="uv-managed CPython $PYVER"
elif command -v "python$PYVER" >/dev/null 2>&1; then
  route="pip"
  PY="python$PYVER"
else
  echo "error: neither uv nor python$PYVER on PATH. Install uv (recommended) or python $PYVER." >&2
  exit 1
fi

if [ "$route" = "pip" ] && ! command -v "$PY" >/dev/null 2>&1; then
  echo "error: $PY not on PATH. Install python $PYVER first." >&2
  exit 1
fi

if [ "$recreate" -eq 1 ] && [ -d "$VENV" ]; then
  echo "removing $VENV"
  rm -rf "$VENV"
fi

if [ ! -d "$VENV" ]; then
  echo "creating venv at $VENV using $PY"
  if [ "$route" = "uv" ]; then
    # pyproject.toml's [tool.uv] python-preference = "only-managed" makes uv
    # refuse to silently fall back to a system/nix interpreter here.
    # --seed keeps pip present for anything that expects it.
    uv python install "$PYVER"
    uv venv --python "$PYVER" --seed "$VENV"
  else
    "$PY" -m venv "$VENV"
  fi
fi

# shellcheck source=/dev/null
source "$VENV/bin/activate"

# Editable install + test, ml, dev extras. The dev extra already pulls in test,
# but listing it explicitly makes the intent obvious and survives extras refactors.
if [ "$route" = "uv" ]; then
  uv pip install --python "$VENV/bin/python3" -e "${ROOT}[test,ml,dev]"
else
  python -m pip install -U pip wheel
  pip install -e "${ROOT}[test,ml,dev]"
fi

# Install the repo's pre-commit hooks if pre-commit is available
if command -v pre-commit >/dev/null 2>&1; then
  ( cd "$ROOT" && pre-commit install )
else
  echo "note: pre-commit not on PATH yet; re-run after activating .venv"
fi

echo
echo "Done. Activate the venv with:"
echo "  source $VENV/bin/activate"
echo
echo "Or install direnv and add a .envrc (already in repo) — it will auto-activate."
echo
echo "Smoke test:"
echo "  pytest yadgar/tests/backend/test_consolidation.py -k cooldown"
