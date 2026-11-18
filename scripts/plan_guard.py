#!/usr/bin/env python3
"""Fail a pipeline run when a Terraform plan would destroy or replace something that holds data or identity.

There is no human approval step in this pipeline, so this is the brake: a plan that deletes or replaces a
protected resource stops the run (and CD never reaches `apply`) unless the exact address is listed in the
allow-list file, which itself needs a commit (so it is reviewed in Git, not clicked through).

Usage:
    terraform show -json tfplan > plan.json
    plan_guard.py plan.json [--allow .github/plan-guard-allow.txt]

Exit codes: 0 fine, 1 blocked, 2 bad input.

Allow-list: one fnmatch pattern per line, matched against the resource address (module path and index
included), `#` starts a comment. Example:
    module.rds.aws_db_instance.this    # engine upgrade, snapshot taken first
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Resource types whose loss is data loss, lockout or an outage that cannot be undone by re-applying.
PROTECTED_TYPES = frozenset(
    {
        "aws_eks_cluster",
        "aws_db_instance",
        "aws_rds_cluster",
        "aws_kms_key",
        "aws_s3_bucket",
        "aws_secretsmanager_secret",
        "aws_vpc",
        "aws_subnet",
        "aws_nat_gateway",
        "aws_eip",
        "aws_iam_openid_connect_provider",
        "aws_ssm_parameter",
        "aws_cloudwatch_log_group",
        "kubernetes_storage_class_v1",
        "kubernetes_namespace_v1",
    }
)


def matches(pattern: str, address: str) -> bool:
    """`*` is the only wildcard. Brackets are literal, so `this[*]` matches `this["rds"]`."""
    regex = re.escape(pattern).replace(r"\*", ".*")
    return re.fullmatch(regex, address) is not None


def load_allow(path: Path | None) -> list[str]:
    if path is None or not path.is_file():
        return []
    patterns = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            patterns.append(line)
    return patterns


def find_blocked(plan: dict, allow: list[str]) -> list[dict]:
    blocked = []
    for rc in plan.get("resource_changes", []):
        actions = rc.get("change", {}).get("actions", [])
        if "delete" not in actions:
            continue
        if rc.get("type") not in PROTECTED_TYPES:
            continue
        address = rc.get("address", "")
        if any(matches(pat, address) for pat in allow):
            continue
        blocked.append(
            {
                "address": address,
                "type": rc.get("type"),
                "kind": "replace" if "create" in actions else "destroy",
                "why": rc.get("action_reason", ""),
            }
        )
    return blocked


def summarize(plan: dict) -> dict[str, int]:
    counts = {"create": 0, "update": 0, "delete": 0, "replace": 0}
    for rc in plan.get("resource_changes", []):
        actions = rc.get("change", {}).get("actions", [])
        if actions == ["create"]:
            counts["create"] += 1
        elif actions == ["update"]:
            counts["update"] += 1
        elif actions == ["delete"]:
            counts["delete"] += 1
        elif "delete" in actions and "create" in actions:
            counts["replace"] += 1
    return counts


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("plan_json", type=Path)
    ap.add_argument("--allow", type=Path, default=None)
    args = ap.parse_args(argv)

    try:
        plan = json.loads(args.plan_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"plan_guard: cannot read plan: {exc}", file=sys.stderr)
        return 2
    if "resource_changes" not in plan and "format_version" not in plan:
        print("plan_guard: this does not look like `terraform show -json` output", file=sys.stderr)
        return 2

    counts = summarize(plan)
    print(
        "plan: {create} to add, {update} to change, {delete} to destroy, {replace} to replace".format(**counts)
    )
    blocked = find_blocked(plan, load_allow(args.allow))
    if not blocked:
        print("plan_guard: ok, nothing protected is destroyed or replaced")
        return 0

    print("plan_guard: BLOCKED. The plan would destroy or replace protected resources:", file=sys.stderr)
    for b in blocked:
        reason = f" ({b['why']})" if b["why"] else ""
        print(f"  - {b['kind']:8} {b['address']}{reason}", file=sys.stderr)
    print(
        "If this is intended, add the address to the allow-list file in a commit and push again.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())