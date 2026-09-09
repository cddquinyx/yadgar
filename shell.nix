# Yadgar dev shell — every NON-Python tool the repo's automation shells out to,
# plus activation of ./.venv for the Python side.
#
# Activated automatically by .envrc (`use flake`), which resolves to
# flake.nix's devShells.default — and that is `import ./shell.nix`, so this file
# is the single source of truth for the dev environment. Enter manually with
# `nix develop` or a bare `nix-shell`; all routes see the same nixpkgs because
# the bare route reads the revision out of flake.lock (see the `pkgs` default).
#
# FIRST ENTRY COST: the full shell pulls chromium, podman, systemd, the mariadb
# client and node — several hundred MB from the binary cache before the first
# `pytest` can run. `nix develop .#lite` / `nix-shell --arg full false` skips
# those (see `full` below) and is enough for the unit suite + lint.
#
# SCOPE — what belongs here and what does not:
#   IN:  system binaries the Makefile / scripts/ / .pre-commit-config.yaml /
#        pytest suite invoke by name (make, git, flock, column, systemd-run,
#        podman, surreal, gitleaks, shellcheck, node, dot, mariadb-dump, ...).
#   OUT: Python packages. Those come from ./.venv (scripts/setup-dev.sh) or
#        `uv run --extra ...`, resolved from uv.lock / the [dev] extra. The
#        pre-commit hooks that lint are `language: system` — they run whatever
#        `ruff` / `mypy` PATH hands them. Putting those here would shadow the
#        venv's resolved version with an unrelated nixpkgs one and silently
#        change lint results, so the venv stays the source of truth for Python
#        (and the shellHook below keeps it first on PATH). `uv` and `pre-commit`
#        ARE here — they bootstrap that venv, and neither is in the [dev] extra.
#
# Anything still missing is deliberate and noted at the bottom of this file.

{
  # Default to the exact nixpkgs revision flake.lock pins, so a bare `nix-shell`
  # and `nix develop` evaluate the same package set. `<nixpkgs>` would follow
  # whatever channel the host happens to have, which differs per machine and
  # silently drifts away from the flake — and, since LD_LIBRARY_PATH below can
  # hand host binaries a libstdc++/openssl from this set, a drifting channel is
  # also how glibc-mismatch failures would creep in.
  pkgs ? (
    let
      lock = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked;
    in
    import (fetchTarball {
      url = "https://github.com/${lock.owner}/${lock.repo}/archive/${lock.rev}.tar.gz";
      sha256 = lock.narHash;
    }) { }
  ),
  # false = the "lite" profile: everything the unit suite, lint and the
  # pre-commit gates need, minus the heavy e2e/browser/container closure
  # (chromium, podman, systemd's dbus clients, mariadb client, node).
  # `make test` still needs systemd-run, so systemd stays in both profiles.
  full ? true,
}:

let
  inherit (pkgs) lib stdenv;

  # requires-python = ">=3.14" (pyproject.toml). Fall back to 3.13 only so the
  # shell still evaluates on a nixpkgs revision predating python314 — the repo
  # itself will refuse to install there.
  python = pkgs.python314 or pkgs.python313;

  # ── SurrealDB, version-pinned ───────────────────────────────────────────────
  # nixpkgs ships surrealdb 2.6.1; this repo pins v3.1.5 everywhere it touches
  # SurrealDB (Dockerfile.backend's `COPY --from=surrealdb/surrealdb:v3.1.5`,
  # Dockerfile.ci's SURREAL_VERSION, scripts/install/restore.sh) and the SurrealQL
  # it emits is written against v3. A 2.x `surreal` on PATH is worse than none:
  # `make e2e` / `make eval` / the e2e conftest only probe
  # `shutil.which("surreal")`, so a v2 binary turns clean skips into confusing
  # query failures. So fetch the same release tarball Dockerfile.ci verifies.
  #
  # All four hashes are SRI. x86_64-linux is the same digest Dockerfile.ci pins
  # as SURREAL_SHA256 (hex there, SRI here — scripts/check_versions.py converts
  # and compares the two on every commit, along with the version itself). The
  # other three came from `nix-prefetch-url` + `nix hash convert --to sri`.
  # Bump all four together with SURREAL_VERSION in Dockerfile.ci.
  surrealVersion = "3.1.5";
  surrealAssets = {
    x86_64-linux = { arch = "linux-amd64"; hash = "sha256-99UVIDugAQveP8alcGznMn01asopP7uoQk1EL13LUAI="; };
    aarch64-linux = { arch = "linux-arm64"; hash = "sha256-o536hFsduXd9cMLrrS3gtmN+2mbguxgIqu4TYoVTRbE="; };
    x86_64-darwin = { arch = "darwin-amd64"; hash = "sha256-38nOkHrGGo/qDHWMZjnLtyruRRHzdaVy1+O+0IHWHSI="; };
    aarch64-darwin = { arch = "darwin-arm64"; hash = "sha256-R2FSvxa5dOE8n4tseLj5H2BcdCHPeyIQZzmRgPy5OUo="; };
  };
  surrealAsset = surrealAssets.${stdenv.hostPlatform.system} or null;

  surreal-pinned = pkgs.stdenvNoCC.mkDerivation {
    pname = "surrealdb-bin";
    version = surrealVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/surrealdb/surrealdb/releases/download/v${surrealVersion}/surreal-v${surrealVersion}.${surrealAsset.arch}.tgz";
      inherit (surrealAsset) hash;
    };
    # Tarball is a bare `surreal` at the root, not in a versioned dir.
    sourceRoot = ".";
    nativeBuildInputs = lib.optionals stdenv.isLinux [ pkgs.autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib pkgs.zlib pkgs.openssl ];
    installPhase = "install -Dm755 surreal $out/bin/surreal";
    meta = {
      description = "SurrealDB ${surrealVersion} release binary (pinned to match Dockerfile.ci)";
      platforms = builtins.attrNames surrealAssets;
      # LICENSE: BUSL-1.1 — NOT an Open Source license. Recorded in
      # THIRD-PARTY-LICENSES (the "Where each component is bundled" table has a
      # row for this dev-shell copy). scripts/check_third_party_licenses.py only
      # scans Dockerfile*, so it does not see this copy; the pin itself is kept
      # in lockstep with Dockerfile.ci by scripts/check_versions.py instead.
      #
      # `meta.license` is deliberately UNSET rather than set to lib.licenses.bsl11:
      # bsl11 is marked unfree, so declaring it makes nix REFUSE TO EVALUATE this
      # shell unless the user exports NIXPKGS_ALLOW_UNFREE=1 — i.e. `direnv allow`
      # would hard-fail for everyone, which defeats the point of this file. This
      # derivation is local dev tooling and is never distributed, so the licensing
      # fact lives in this comment and in THIRD-PARTY-LICENSES instead.
    };
  };

  # Fall back to nixpkgs on a platform without a pinned asset rather than
  # failing evaluation outright.
  surreal = if surrealAsset != null then surreal-pinned else pkgs.surrealdb;

  # Native libs that pip/uv-installed manylinux wheels dlopen at import time.
  # Without these on LD_LIBRARY_PATH, `import torch` / scipy / numpy inside
  # ./.venv dies with "libstdc++.so.6: cannot open shared object file" on NixOS
  # — which takes out the [ml] extra and therefore `make test`, `make e2e`,
  # `make eval` and every embedding test.
  wheelRuntimeLibs = [
    stdenv.cc.cc.lib # libstdc++, libgomp — torch, scipy, onnxruntime
    pkgs.zlib
    pkgs.openssl
    pkgs.libffi
    pkgs.bzip2
    pkgs.xz
    pkgs.sqlite
  ];
in

pkgs.mkShell {
  name = "yadgar-dev";

  packages = [
    # ── Python + the two bootstrappers ──────────────────────────────────────
    # Fallback interpreter only: scripts/setup-dev.sh prefers a uv-managed
    # CPython (see UV_PYTHON in the shellHook) and reaches for `python3.14`
    # on PATH only when uv is unavailable.
    python
    pkgs.uv # `uv run --extra test`, uv.lock, scripts/sync_uv_lock.py
    pkgs.pre-commit # NOT in the [dev] extra; CI pip-installs it, we supply it

    # C toolchain — `pip install -e .[ml]` builds sdists (no wheel for every
    # dep on every platform) and needs a compiler + pkg-config.
    stdenv.cc
    pkgs.pkg-config

    # ── Make + POSIX userland ───────────────────────────────────────────────
    # The Makefile hard-errors on non-GNU make (top-of-file $(error) guard) and
    # `make help` pipes through `column -t -s :`.
    pkgs.gnumake
    pkgs.bashInteractive # SHELL := /usr/bin/env bash -euo pipefail
    pkgs.coreutils # timeout (test-capped.sh), sha256sum, stat, id, install
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
    pkgs.findutils
    pkgs.diffutils
    pkgs.gnutar
    pkgs.gzip
    pkgs.xz
    pkgs.which
    pkgs.procps # pgrep/ps — scripts/reap-test-surreal.sh, reap-stale-tests.sh
    pkgs.rsync

    # ── VCS + repo gates ───────────────────────────────────────────────────
    pkgs.git # branch detection, merge-base diffs in check_backend_bump.py
    pkgs.gitleaks # pre-commit `Detect secrets and credentials` (Dockerfile.ci pins 8.30.1)
    pkgs.shellcheck # yadgar/tests/scripts/test_v5_46_0_yadgar_setup_render.py
    pkgs.curl
    pkgs.jq

    # ── Databases ──────────────────────────────────────────────────────────
    surreal # e2e/eval/longmemeval + every surreal_server fixture

    # ── Diagram test deps ──────────────────────────────────────────────────
    pkgs.graphviz # `dot` — test_diagram_generator render tests
  ]
  ++ lib.optionals full [
    # ── Heavy, `full` profile only ─────────────────────────────────────────
    pkgs.mariadb.client # mariadb / mariadb-dump — the SQL dump+restore arms

    # Container runtime: `make pull-images`, scripts/install/detect_runtime.sh,
    # and the tests that start a real mariadb container. See the NOTE at the
    # bottom of this file.
    pkgs.podman

    # Node / JS surfaces: sdk-js (tsup/vitest/tsc) + viz-tests (vitest) + the
    # opencode plugin smoke in yadgar/tests/clients/, which runs
    # `node --experimental-strip-types` (needs >= 22.6). npm/npx ship with it.
    pkgs.nodejs_22
  ]
  ++ lib.optionals stdenv.isLinux [
    # flock (Makefile's $(LOCKED) macro + scripts/ci-local-legs.sh), column
    # (`make help`), logger. Linux-only: the darwin build ships a subset that
    # omits flock, and the Makefile's locking is Linux-shaped anyway.
    pkgs.util-linux

    # systemd-run --user --scope. scripts/test-capped.sh FAILS CLOSED without
    # it (refuses to run unless TEST_ALLOW_UNCAPPED=1), so `make test`,
    # `make test-ci`, `make ci-local`, `make e2e`, `make eval`, `make perf` and
    # `make check` all depend on this binary existing. Also systemctl for
    # `make enable-units` / uninstall.sh, and systemd-analyze for the unit-lint
    # tests. Verified working against a host init of a different version — these
    # are dbus clients, not the init itself.
    pkgs.systemd
  ]
  ++ lib.optionals (full && stdenv.isLinux) [
    # Playwright's viz smoke tests. yadgar/tests/integration/viz/conftest.py
    # prefers a system chromium ("NixOS-safe" per its own docstring) over
    # playwright's bundled download, which cannot run on NixOS at all.
    pkgs.chromium
  ];

  shellHook = ''
    # ── ./.venv owns the Python side, and must win over the nix python ─────
    # This is the ONE place the venv is activated (.envrc deliberately does not
    # — see its header). Without it the nix interpreter shadows the venv and
    # `python3 -m yadgar ...` (make install-hooks / install-agents /
    # config-sync / seed-anchors) plus every console script (pytest, ruff,
    # mypy, lint-imports, cyclonedx-py) resolve to an interpreter with nothing
    # installed.
    #
    # The repo root, not $PWD: `nix develop` copies the tree to the store, so
    # a nix path literal here would point INTO /nix/store, and $PWD is wrong
    # for a `nix-shell ../shell.nix` from a subdirectory. git is in this shell.
    yadgar_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    # Prepended UNCONDITIONALLY, on purpose: a not-yet-created .venv/bin is
    # simply skipped during PATH lookup, and starts resolving the moment
    # scripts/setup-dev.sh creates it — no `direnv reload` needed, even though
    # nix-direnv caches this env. A guard would bake "no venv" into that cache.
    PATH="$yadgar_root/.venv/bin:$PATH"
    export PATH

    # VIRTUAL_ENV is guarded, unlike PATH: uv warns when it points at a
    # directory that does not exist. The venv does not need it to work.
    if [ -d "$yadgar_root/.venv" ]; then
      export VIRTUAL_ENV="$yadgar_root/.venv"
    else
      echo "yadgar shell: no ./.venv yet — run ./scripts/setup-dev.sh" >&2
    fi

    # ── LD_LIBRARY_PATH: only for the nix-python override, never by default ─
    # The default ./.venv interpreter is a uv-managed CPython (see below), an
    # ordinary non-nix binary that nix-ld already serves on NixOS and that
    # needs nothing on any other distro. Exporting LD_LIBRARY_PATH anyway would
    # hand nixpkgs' libstdc++/openssl/zlib to EVERY child of this shell — host
    # binaries like ssh/gpg on a non-NixOS box, and on NixOS a nixpkgs revision
    # that need not match the glibc nix-ld loads. So it is scoped to the one
    # case that needs it: a caller who forced UV_PYTHON_PREFERENCE away from
    # only-managed and therefore has a nix interpreter in ./.venv, whose
    # manylinux wheels dlopen these libs at import time (wheelRuntimeLibs).
    case "''${UV_PYTHON_PREFERENCE:-only-managed}" in
      only-managed) ;;
      *) export LD_LIBRARY_PATH="${lib.makeLibraryPath wheelRuntimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
    esac

    # ── ./.venv must be built on a uv-MANAGED CPython, NOT the nix one ─────
    # nix-ld is what makes ordinary manylinux wheels work on this host, and it
    # only intercepts NON-nix binaries — a nix interpreter never gets
    # libstdc++ from it. Inside this shell that is papered over by the
    # LD_LIBRARY_PATH export above, but anything running ./.venv/bin/python3
    # WITHOUT this shell in scope gets no such help. Claude Code spawns the
    # yadgar hooks exactly that way, and every one of them died silently on
    #     ImportError: libstdc++.so.6: cannot open shared object file
    # A uv-downloaded CPython is a plain non-nix binary, so nix-ld serves it
    # everywhere and no interpreter wrapper/shim is needed.
    #
    # This is not only about `uv venv` at bootstrap: `make test` / `make e2e` /
    # `make eval` go through `uv run --extra ...`, which re-syncs ./.venv and
    # RECREATES it when its interpreter does not match this request. Pinning
    # the nix python here would rebuild the venv on it behind every test run
    # and silently re-break the hooks. only-managed is what keeps it stuck.
    #
    # The policy itself lives in REPO CONFIG, not here: `.python-version`
    # (3.14) and `[tool.uv] python-preference = "only-managed"` in
    # pyproject.toml. uv reads both from the working tree, so `uv run` from a
    # cron job, a Claude Code hook or CI behaves identically to `uv run` inside
    # this shell, and nothing has to be exported. An env var still wins over
    # pyproject, so `UV_PYTHON_PREFERENCE=system nix-shell` remains the escape
    # hatch for a host where downloads are unwanted — that is the case the
    # LD_LIBRARY_PATH block above exists for.

    # TLS roots for curl / uv / pip / huggingface_hub on non-NixOS hosts.
    export SSL_CERT_FILE="''${SSL_CERT_FILE:-${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"

    ${lib.optionalString stdenv.isLinux ''
      # Mirrors Dockerfile.ci-viz: use the nix chromium, skip the 200MB
      # bundled-browser download that would not run on NixOS regardless.
      export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="${pkgs.chromium}/bin/chromium"
      export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    ''}
  '';

  # ── Deliberately NOT provided ─────────────────────────────────────────────
  # * ruff / mypy / pytest / import-linter / cyclonedx-py / mutmut — Python
  #   tooling, owned by ./.venv + uv.lock (see SCOPE at the top).
  # * launchctl / plutil / sw_vers — macOS system binaries; Apple-only, cannot
  #   be packaged. `make enable-units-macos` needs the host's.
  # * nixos-version / home-manager — scripts/install/detect_os.sh probes these
  #   to IDENTIFY a NixOS host. Supplying them would make every host answer
  #   "linux-nixos" and trip the `make setup` NixOS guard.
  # * codebase-memory-mcp — not in nixpkgs; built by flake.nix and installed by
  #   `make code-graph-install`.
  # * The HuggingFace model weights Dockerfile.ci bakes — downloaded on first
  #   use into $HF_HOME, not a nix input.
  #
  # NOTE on podman: rootless podman also needs host-side state nix cannot ship
  # (/etc/subuid + /etc/subgid, newuidmap/newgidmap setuid helpers,
  # /etc/containers/policy.json). On NixOS set `virtualisation.podman.enable`;
  # elsewhere the distro package sets it up. The binary here is what
  # detect_runtime.sh looks for, not a complete rootless install.
}
