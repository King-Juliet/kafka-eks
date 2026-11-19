#!/usr/bin/env python3
"""Run one of the tested ETL scripts on the secured platform.

The scripts in producer/ and consumers/ were written and tested against a local
plaintext broker. Their only change for the platform: the broker address is read
from the KAFKA_BOOTSTRAP_SERVERS environment variable instead of being written in
the file (on the instances, render-env.sh pulls it from Secrets Manager before
every start). Two things still stop them from running as-is, and this launcher
fixes both at runtime:

1. Kafka security. The scripts use no security settings. The platform listener is
   SASL_SSL with SCRAM-SHA-512. The launcher wraps ``confluent_kafka.Producer``,
   ``Consumer`` and ``admin.AdminClient`` so every config dict the scripts build
   gets the real connection settings merged in (override wins), including the
   same bootstrap address, so the two can never disagree. Everything else the
   scripts set (acks, group.id, fetch sizes, ...) is left alone.

2. Imports. ``bitcoin_etl_main.py`` does ``from .bitcoin_etl_helpers import ...``
   (a relative import) but the scripts import it as a top-level module, which
   fails with "attempted relative import with no known parent package". The
   launcher loads both modules under a throw-away package and registers them in
   ``sys.modules`` under the plain names the scripts use.

Usage (always from the directory that holds the log file, see the systemd unit):

    python launcher.py producer/block_data_producer.py
    python launcher.py consumers/block_data_consumer.py
    python launcher.py ops/lag_publisher.py

Environment (written to /etc/bitcoin-etl/env by render-env.sh on the instances):

    KAFKA_BOOTSTRAP_SERVERS   required, host:port[,host:port]
    KAFKA_USERNAME            required for SASL protocols
    KAFKA_PASSWORD            required for SASL protocols
    KAFKA_CA_FILE             path to the cluster CA PEM (needed for SSL protocols
                              when the CA is not a public one)
    KAFKA_SECURITY_PROTOCOL   optional, default SASL_SSL (PLAINTEXT for local dev)
    KAFKA_SASL_MECHANISM      optional, default SCRAM-SHA-512
"""

from __future__ import annotations

import importlib
import os
import runpy
import sys
import types
from collections.abc import Mapping, MutableMapping
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent

# Directories whose scripts import bitcoin_etl_helpers / bitcoin_etl_main.
ETL_DIRS = frozenset({"producer", "consumers"})
ETL_MODULES = ("bitcoin_etl_helpers", "bitcoin_etl_main")
PKG_NAME = "bitcoin_etl_pkg"
PATCH_MARK = "_bitcoin_etl_launcher_patched"


class LauncherError(RuntimeError):
    """Configuration problem. Raised before any Kafka client is created."""


def build_overrides(env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Return the librdkafka settings that must win over whatever a script sets."""
    env = os.environ if env is None else env

    bootstrap = env.get("KAFKA_BOOTSTRAP_SERVERS", "").strip()
    if not bootstrap:
        raise LauncherError("KAFKA_BOOTSTRAP_SERVERS is not set")

    protocol = env.get("KAFKA_SECURITY_PROTOCOL", "SASL_SSL").strip().upper()
    if protocol not in {"PLAINTEXT", "SSL", "SASL_PLAINTEXT", "SASL_SSL"}:
        raise LauncherError(f"unsupported KAFKA_SECURITY_PROTOCOL: {protocol}")

    overrides: dict[str, Any] = {
        "bootstrap.servers": bootstrap,
        "security.protocol": protocol,
    }

    if protocol.startswith("SASL"):
        username = env.get("KAFKA_USERNAME", "").strip()
        password = env.get("KAFKA_PASSWORD", "")
        if not username or not password:
            raise LauncherError("KAFKA_USERNAME and KAFKA_PASSWORD are required for SASL")
        overrides["sasl.mechanism"] = env.get("KAFKA_SASL_MECHANISM", "SCRAM-SHA-512").strip()
        overrides["sasl.username"] = username
        overrides["sasl.password"] = password

    if protocol.endswith("SSL"):
        ca_file = env.get("KAFKA_CA_FILE", "").strip()
        if ca_file:
            if not Path(ca_file).is_file():
                raise LauncherError(f"KAFKA_CA_FILE does not exist: {ca_file}")
            overrides["ssl.ca.location"] = ca_file

    return overrides


def merge_conf(
    conf: Mapping[str, Any] | None, overrides: Mapping[str, Any]
) -> MutableMapping[str, Any]:
    """Copy of the script's config with the overrides applied on top."""
    merged: dict[str, Any] = dict(conf or {})
    merged.update(overrides)
    return merged


def _secured(base: type, overrides: Mapping[str, Any]) -> type:
    """Subclass of a confluent_kafka client class that merges overrides at init."""

    class Secured(base):  # type: ignore[misc, valid-type]
        def __init__(self, conf: Mapping[str, Any] | None = None, *args: Any, **kwargs: Any):
            super().__init__(merge_conf(conf, overrides), *args, **kwargs)

    Secured.__name__ = base.__name__
    Secured.__qualname__ = base.__qualname__
    setattr(Secured, PATCH_MARK, True)
    return Secured


def patch_kafka(overrides: Mapping[str, Any]) -> None:
    """Replace the client classes the scripts import with override-merging subclasses.

    Must run before a script executes its ``from confluent_kafka import ...``.
    """
    import confluent_kafka
    import confluent_kafka.admin as kafka_admin

    for module, name in (
        (confluent_kafka, "Producer"),
        (confluent_kafka, "Consumer"),
        (kafka_admin, "AdminClient"),
    ):
        current = getattr(module, name)
        if getattr(current, PATCH_MARK, False):
            continue
        setattr(module, name, _secured(current, overrides))


def alias_etl_modules(root: Path = ROOT) -> None:
    """Make ``bitcoin_etl_main``'s relative import work without editing the file."""
    pkg = types.ModuleType(PKG_NAME)
    pkg.__path__ = [str(root)]  # type: ignore[attr-defined]
    sys.modules[PKG_NAME] = pkg
    for name in ETL_MODULES:  # helpers first: main imports it relatively
        sys.modules[name] = importlib.import_module(f"{PKG_NAME}.{name}")


def resolve_script(relative: str, root: Path = ROOT) -> Path:
    script = (root / relative).resolve()
    if root.resolve() not in script.parents:
        raise LauncherError(f"script must be inside {root}: {relative}")
    if script.suffix != ".py" or not script.is_file():
        raise LauncherError(f"script not found: {relative}")
    return script


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        script = resolve_script(argv[1])
        patch_kafka(build_overrides())
    except LauncherError as err:
        print(f"launcher: {err}", file=sys.stderr)
        return 2

    if script.parent.name in ETL_DIRS:
        alias_etl_modules()

    sys.argv = [str(script), *argv[2:]]
    runpy.run_path(str(script), run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
    