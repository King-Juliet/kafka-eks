#!/usr/bin/env python3
"""Prepare the ETL database. Run by CD from inside the VPC (the database is private).

1. Make sure the application user exists and its credentials are stored in Secrets Manager.
   The RDS master password is rotated by RDS, which would break the running ETL, so the ETL gets its own
   user with a password that only this script sets (alphanumeric, so systemd env files can hold it).
2. Apply db/migrations/V###__*.sql as that application user (so it owns what it creates), once each, in order.
   Applied files are recorded with a checksum; editing an applied file is an error (add a new version instead).

Idempotent: running it again changes nothing unless there is a new migration. Safe to run concurrently
(a PostgreSQL advisory lock serialises runs).

Usage:
    db_migrate.py --host H --port 5432 --dbname bitcoin_db \\
        --master-secret-arn ARN --app-secret-id /kafka-eks/db/etl-app [--migrations-dir db/migrations]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import secrets
import string
import sys
import time
from pathlib import Path

ADVISORY_LOCK_KEY = 727_274_001  # arbitrary, fixed: "the ETL migrations lock"
MIGRATION_NAME = re.compile(r"^V(\d+)__[A-Za-z0-9_\-]+\.sql$")
ALPHABET = string.ascii_letters + string.digits


class MigrationError(RuntimeError):
    pass


def generate_password(length: int = 40) -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(length))


def checksum(text: str) -> str:
    return hashlib.sha256(text.replace("\r\n", "\n").encode("utf-8")).hexdigest()


def discover(directory: Path) -> list[tuple[int, Path]]:
    found: list[tuple[int, Path]] = []
    for path in sorted(directory.glob("*.sql")):
        m = MIGRATION_NAME.match(path.name)
        if not m:
            raise MigrationError(f"{path.name}: migration files must be named V<number>__<description>.sql")
        found.append((int(m.group(1)), path))
    versions = [v for v, _ in found]
    if len(versions) != len(set(versions)):
        raise MigrationError("two migration files share a version number")
    return sorted(found)


def plan(found: list[tuple[int, Path]], applied: dict[int, str]) -> list[tuple[int, Path]]:
    """Which files still have to run. Raises if an applied file was edited or is missing."""
    by_version = dict(found)
    for version, old_sum in applied.items():
        path = by_version.get(version)
        if path is None:
            raise MigrationError(f"version {version} was applied but its file is gone")
        if checksum(path.read_text(encoding="utf-8")) != old_sum:
            raise MigrationError(f"{path.name} was changed after it was applied; add a new migration instead")
    return [(v, p) for v, p in found if v not in applied]


# ---------------------------------------------------------------- AWS

def read_json_secret(client, secret_id: str) -> dict | None:
    try:
        value = client.get_secret_value(SecretId=secret_id)["SecretString"]
    except client.exceptions.ResourceNotFoundException:
        return None
    except client.exceptions.ClientError as exc:  # an empty shell has no AWSCURRENT version yet
        if "AWSCURRENT" in str(exc) or "can't find the specified secret value" in str(exc):
            return None
        raise
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return None


def ensure_app_credentials(client, secret_id: str, username: str) -> dict:
    """Return {username, password}; create and store them first if the secret is still empty."""
    current = read_json_secret(client, secret_id)
    if current and current.get("username") == username and current.get("password"):
        return {"username": username, "password": current["password"]}
    creds = {"username": username, "password": generate_password()}
    client.put_secret_value(SecretId=secret_id, SecretString=json.dumps(creds))
    return creds


# ---------------------------------------------------------------- PostgreSQL

def connect(host, port, dbname, user, password, attempts=30, delay=10, sslmode="require"):
    import psycopg2

    last = None
    for _ in range(attempts):
        try:
            return psycopg2.connect(
                host=host, port=port, dbname=dbname, user=user, password=password,
                sslmode=sslmode, connect_timeout=10,
            )
        except psycopg2.OperationalError as exc:
            last = exc
            print(f"database not reachable yet ({exc.__class__.__name__}); retrying in {delay}s", flush=True)
            time.sleep(delay)
    raise MigrationError(f"could not connect to {host}:{port}: {last}")


def ensure_role(master_conn, dbname: str, username: str, password: str) -> None:
    from psycopg2 import sql

    with master_conn, master_conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (username,))
        if cur.fetchone() is None:
            cur.execute(sql.SQL("CREATE ROLE {} LOGIN").format(sql.Identifier(username)))
        # Always (re)set it so the database matches the secret even after a partial earlier run.
        cur.execute(
            sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(sql.Identifier(username), sql.Literal(password))
        )
        cur.execute(
            sql.SQL("GRANT CONNECT, CREATE ON DATABASE {} TO {}").format(
                sql.Identifier(dbname), sql.Identifier(username)
            )
        )
        cur.execute(sql.SQL("GRANT ALL ON SCHEMA public TO {}").format(sql.Identifier(username)))


def applied_versions(conn) -> dict[int, str]:
    with conn, conn.cursor() as cur:
        cur.execute(
            """CREATE TABLE IF NOT EXISTS schema_migrations (
                   version    INTEGER PRIMARY KEY,
                   filename   TEXT NOT NULL,
                   checksum   TEXT NOT NULL,
                   applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
               )"""
        )
        cur.execute("SELECT version, checksum FROM schema_migrations")
        return {int(v): c for v, c in cur.fetchall()}


def apply_migrations(conn, directory: Path) -> list[str]:
    done: list[str] = []
    with conn.cursor() as cur:
        cur.execute("SELECT pg_advisory_lock(%s)", (ADVISORY_LOCK_KEY,))
    conn.commit()
    try:
        todo = plan(discover(directory), applied_versions(conn))
        for version, path in todo:
            text = path.read_text(encoding="utf-8")
            with conn, conn.cursor() as cur:  # one transaction per file: all of it or none of it
                cur.execute(text)
                cur.execute(
                    "INSERT INTO schema_migrations (version, filename, checksum) VALUES (%s, %s, %s)",
                    (version, path.name, checksum(text)),
                )
            done.append(path.name)
            print(f"applied {path.name}", flush=True)
    finally:
        with conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_unlock(%s)", (ADVISORY_LOCK_KEY,))
        conn.commit()
    return done


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=5432)
    ap.add_argument("--dbname", required=True)
    ap.add_argument("--master-secret-arn", required=True)
    ap.add_argument("--app-secret-id", required=True)
    ap.add_argument("--app-username", default="etl_app")
    ap.add_argument("--migrations-dir", type=Path, default=Path("db/migrations"))
    ap.add_argument("--region", default=None)
    ap.add_argument("--sslmode", default="require", help="require for RDS; only tests use something else")
    args = ap.parse_args(argv)

    import boto3
    import psycopg2

    sm = boto3.client("secretsmanager", region_name=args.region)
    try:
        # Fail on a bad migrations folder before touching anything.
        discover(args.migrations_dir)
        master = read_json_secret(sm, args.master_secret_arn)
        if not master or "username" not in master or "password" not in master:
            raise MigrationError("master secret is empty or has no username/password")
        creds = ensure_app_credentials(sm, args.app_secret_id, args.app_username)

        master_conn = connect(
            args.host, args.port, args.dbname, master["username"], master["password"], sslmode=args.sslmode
        )
        try:
            ensure_role(master_conn, args.dbname, creds["username"], creds["password"])
        finally:
            master_conn.close()

        app_conn = connect(
            args.host, args.port, args.dbname, creds["username"], creds["password"], sslmode=args.sslmode
        )
        try:
            done = apply_migrations(app_conn, args.migrations_dir)
        finally:
            app_conn.close()
    except MigrationError as exc:
        print(f"db_migrate: {exc}", file=sys.stderr)
        return 1
    except psycopg2.Error as exc:
        print(f"db_migrate: database error: {exc}", file=sys.stderr)
        return 1
    print(f"db_migrate: ok ({len(done)} migration(s) applied)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
