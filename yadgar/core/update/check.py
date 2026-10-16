"""v5.48.0 — Anonymous version-check probe against PyPI JSON API.

Spec:
  GET https://pypi.org/pypi/yadgar/json
  User-Agent: yadgar/<version>
  Accept: application/json

Response: .info.version → available_version string.

Privacy posture: no auth, no cookies, no user-ID, no IP. Version-only.
Corporate firewalls: respects HTTPS_PROXY env (httpx default behavior).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import UTC, datetime

import httpx

from yadgar import __version__
from yadgar._shared.observability.observe import observe

_PYPI_URL = "https://pypi.org/pypi/yadgar/json"
_DEFAULT_TIMEOUT = 5
_RELEASE_SEGMENT = re.compile(r"\d+(?:\.\d+)*")


@observe(tier="hot")
def is_newer(available: str, current: str) -> bool:
    """Return True when *available* is a strictly later release than *current*.

    Compares the numeric release segment (``5.195.1`` of ``5.195.1rc1+local``),
    zero-padded so ``5.195`` equals ``5.195.0``. A plain inequality test used to
    stand here, so a source checkout ahead of PyPI was told to "update" to an
    older release. If either string has no numeric release segment, nothing is
    claimed to be newer.
    """
    a = _RELEASE_SEGMENT.match(available.strip())
    c = _RELEASE_SEGMENT.match(current.strip())
    if a is None or c is None:
        return False
    av = [int(p) for p in a.group().split(".")]
    cv = [int(p) for p in c.group().split(".")]
    width = max(len(av), len(cv))
    av += [0] * (width - len(av))
    cv += [0] * (width - len(cv))
    return av > cv


@dataclass
class LatestVersionInfo:
    """Result of a PyPI version probe."""

    available_version: str
    checked_at: str = field(default_factory=lambda: datetime.now(UTC).isoformat())


@observe(tier="boundary")
def probe_latest_version(
    *,
    url: str = _PYPI_URL,
    timeout: int = _DEFAULT_TIMEOUT,
) -> LatestVersionInfo:
    """Probe PyPI JSON API for the latest yadgar version.

    Args:
        url: PyPI JSON endpoint (override in tests via settings).
        timeout: HTTP timeout in seconds.

    Returns:
        LatestVersionInfo with available_version populated.

    Raises:
        httpx.TimeoutException: request exceeded timeout.
        httpx.HTTPStatusError: non-2xx response.
        httpx.ConnectError: network unreachable / DNS failure.
    """
    headers = {
        "User-Agent": f"yadgar/{__version__}",
        "Accept": "application/json",
    }
    resp = httpx.get(url, headers=headers, timeout=timeout, follow_redirects=True)
    resp.raise_for_status()
    data = resp.json()
    available = data["info"]["version"]
    return LatestVersionInfo(available_version=available)
