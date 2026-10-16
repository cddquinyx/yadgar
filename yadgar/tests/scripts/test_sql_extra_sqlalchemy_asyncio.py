"""pyproject.toml [sql] extra must install SQLAlchemy's asyncio support (greenlet).

SQLAlchemy 2.0 pulled greenlet in on x86_64/aarch64 by default; 2.1 does not, and
`sqlalchemy.ext.asyncio` then raises ImportError at engine creation. The backend
image installs `/app[ml,sql]` unpinned (Dockerfile.backend), so a fresh build
resolved 2.1.4 without greenlet and the engine-#2 migration killed the backend
on start. Requesting the `asyncio` extra makes greenlet a declared dependency on
every SQLAlchemy version.
"""

import re
import tomllib

from yadgar.tests._paths import REPO_ROOT

PYPROJECT = REPO_ROOT / "pyproject.toml"

# PEP 508 head: distribution name, then an optional [extra, ...] list.
_REQ_HEAD = re.compile(r"^\s*([A-Za-z0-9._-]+)\s*(?:\[([^\]]*)\])?")


def _sql_extras_by_name() -> dict[str, set[str]]:
    data = tomllib.loads(PYPROJECT.read_text())
    out: dict[str, set[str]] = {}
    for req in data["project"]["optional-dependencies"]["sql"]:
        m = _REQ_HEAD.match(req)
        assert m, f"unparseable requirement in [sql]: {req!r}"
        out[m.group(1).lower()] = {e.strip() for e in (m.group(2) or "").split(",") if e.strip()}
    return out


def test_sql_extra_requests_sqlalchemy_asyncio() -> None:
    extras = _sql_extras_by_name().get("sqlalchemy")
    assert extras is not None, "[sql] extra must declare sqlalchemy"
    assert "asyncio" in extras, (
        f"[sql] must declare sqlalchemy[asyncio] so greenlet is installed; got extras {extras}"
    )
