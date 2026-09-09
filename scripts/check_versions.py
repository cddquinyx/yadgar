#!/usr/bin/env python3
"""Check version consistency across pyproject.toml, server.json, docker-compose.yml, uv.lock, and flake.nix.

Also checks that shell.nix's pinned SurrealDB release (version + x86_64-linux
hash) tracks Dockerfile.ci's SURREAL_VERSION / SURREAL_SHA256. The two are
pinned independently in two syntaxes (hex in the Dockerfile, SRI in nix), and
scripts/check_third_party_licenses.py only scans Dockerfile*, so nothing else
would notice the dev shell drifting onto a different surreal than CI.
"""

import base64
import json
import re
import sys
from pathlib import Path

root = Path(__file__).parent.parent

# --- extract versions ---

toml_text = (root / "pyproject.toml").read_text()
m = re.search(r'^version\s*=\s*"([^"]+)"', toml_text, re.MULTILINE)
if not m:
    print("ERROR: version not found in pyproject.toml", file=sys.stderr)
    sys.exit(1)
pyproject_version = m.group(1)

server_data = json.loads((root / "server.json").read_text())
server_core_version = server_data.get("version", "")
server_backend_version = server_data.get("backend_version", "")
server_pkg_versions = [p.get("version", "") for p in server_data.get("packages", [])]

compose_text = (root / "docker-compose.yml").read_text()
m_core = re.search(r"\$\{CORE_VERSION:-([^}]+)\}", compose_text)
m_backend = re.search(r"\$\{BACKEND_VERSION:-([^}]+)\}", compose_text)
compose_core_version = m_core.group(1) if m_core else ""
compose_backend_version = m_backend.group(1) if m_backend else ""

uv_lock_path = root / "uv.lock"
uv_version = ""
if uv_lock_path.exists():
    uv_text = uv_lock_path.read_text()
    m_uv = re.search(r'\[\[package\]\]\nname = "yadgar"\nversion = "([^"]+)"', uv_text)
    if m_uv:
        uv_version = m_uv.group(1)

flake_nix_path = root / "flake.nix"
flake_version = ""
if flake_nix_path.exists():
    flake_text = flake_nix_path.read_text()
    m_flake = re.search(r'^\s*version\s*=\s*"([^"]+)";', flake_text, re.MULTILINE)
    if m_flake:
        flake_version = m_flake.group(1)

# shell.nix pins the SurrealDB release Dockerfile.ci also pins. Compare the
# version and the x86_64-linux digest (Dockerfile hex -> SRI for the comparison).
surreal_rows: list[tuple[str, str, str]] = []
dockerfile_ci_path = root / "Dockerfile.ci"
shell_nix_path = root / "shell.nix"
if dockerfile_ci_path.exists() and shell_nix_path.exists():
    ci_text = dockerfile_ci_path.read_text()
    nix_text = shell_nix_path.read_text()
    m_ci_ver = re.search(r"^ARG SURREAL_VERSION=v?([^\s]+)", ci_text, re.MULTILINE)
    m_ci_sha = re.search(r"^ARG SURREAL_SHA256=([0-9a-fA-F]{64})", ci_text, re.MULTILINE)
    m_nix_ver = re.search(r'^\s*surrealVersion\s*=\s*"([^"]+)";', nix_text, re.MULTILINE)
    m_nix_sha = re.search(r'x86_64-linux\s*=\s*\{[^}]*hash\s*=\s*"(sha256-[^"]+)"', nix_text)
    if m_ci_ver and m_nix_ver:
        surreal_rows.append(("Dockerfile.ci SURREAL_VERSION", "surreal", m_ci_ver.group(1)))
        surreal_rows.append(("shell.nix surrealVersion", "surreal", m_nix_ver.group(1)))
    if m_ci_sha and m_nix_sha:
        ci_sri = "sha256-" + base64.b64encode(bytes.fromhex(m_ci_sha.group(1))).decode()
        surreal_rows.append(("Dockerfile.ci SURREAL_SHA256 (as SRI)", "surreal-sha", ci_sri))
        surreal_rows.append(("shell.nix x86_64-linux hash", "surreal-sha", m_nix_sha.group(1)))

# --- build comparison table ---

rows = [
    ("pyproject.toml", "core", pyproject_version),
    ("server.json version", "core", server_core_version),
    ("server.json backend_ver", "backend", server_backend_version),
    ("docker-compose CORE", "core", compose_core_version),
    ("docker-compose BACKEND", "backend", compose_backend_version),
]
if uv_version:
    rows.append(("uv.lock", "core", uv_version))
if flake_version:
    rows.append(("flake.nix", "core", flake_version))
for i, pkg_ver in enumerate(server_pkg_versions):
    rows.append((f"server.json packages[{i}]", "core", pkg_ver))
rows.extend(surreal_rows)

# --- determine canonical versions ---

core_versions = {v for src, role, v in rows if role == "core" and v}
backend_versions = {v for src, role, v in rows if role == "backend" and v}
surreal_versions = {v for src, role, v in rows if role == "surreal" and v}
surreal_shas = {v for src, role, v in rows if role == "surreal-sha" and v}

mismatches = []
if len(core_versions) > 1:
    mismatches.append(("core", core_versions))
if len(backend_versions) > 1:
    mismatches.append(("backend", backend_versions))
if len(surreal_versions) > 1:
    mismatches.append(("surreal", surreal_versions))
if len(surreal_shas) > 1:
    mismatches.append(("surreal-sha", surreal_shas))

# NOTE: core and backend versions are tracked independently since v4.7.0
# (split-versions feature). They are NOT required to match — only the
# intra-role checks above are enforced.

if not mismatches:
    sys.exit(0)

# --- print diff table ---

col_src = max(len(src) for src, _, _ in rows)
col_role = max(len(role) for _, role, _ in rows)
col_ver = max(len(v) for _, _, v in rows)
header = f"{'source':<{col_src}}  {'role':<{col_role}}  {'version':<{col_ver}}"
sep = "-" * len(header)

print("VERSION MISMATCH DETECTED", file=sys.stderr)
print(sep, file=sys.stderr)
print(header, file=sys.stderr)
print(sep, file=sys.stderr)
for src, role, ver in rows:
    print(f"{src:<{col_src}}  {role:<{col_role}}  {ver:<{col_ver}}", file=sys.stderr)
print(sep, file=sys.stderr)
for label, versions in mismatches:
    print(f"  conflict ({label}): {', '.join(sorted(versions))}", file=sys.stderr)

sys.exit(1)
