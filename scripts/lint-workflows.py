#!/usr/bin/env python3
"""Validate the workflow files.

A script rather than inline in check.yml because GitHub scans the entire
workflow file for ${{ ... }} sequences -- including inside run: block scalars --
and tries to parse each one. A linter looking for mixed conditionals necessarily
contains the characters it searches for, so inline it would make the workflow
itself invalid.

Three checks:

  1. Every workflow parses as YAML.

  2. No `if:` mixes an expression with literal text. In `if: <expr> && B`, with
     <expr> braced and B not, GitHub evaluates the whole value as a string --
     always truthy -- and silently ignores B. It surfaces only as a workflow
     annotation after a push, which is too late.
"""
import glob
import re
import subprocess
import sys

import yaml

# Built rather than written literally, so this file never contains the sequence
# it looks for -- grepping the repo for the bug would otherwise match the linter.
OPEN = "$" + "{{"
CLOSE = "}" + "}"
EXPR = re.compile(re.escape(OPEN) + r".*?" + re.escape(CLOSE))
IF_LINE = re.compile(r"\s*if:\s*(.+?)\s*$")


def main() -> int:
    files = sorted(glob.glob(".github/workflows/*.yml"))
    if not files:
        print("no workflow files found", file=sys.stderr)
        return 1

    bad = 0
    for path in files:
        try:
            yaml.safe_load(open(path))
        except Exception as exc:                       # noqa: BLE001
            print(f"::error file={path}::invalid YAML: {exc}")
            bad += 1
            continue

        for num, line in enumerate(open(path), 1):
            match = IF_LINE.match(line)
            if not match:
                continue
            value = match.group(1)
            if OPEN not in value:
                continue                               # plain expression, fine
            outside = EXPR.sub("", value).strip()
            if outside:
                print(
                    f"::error file={path},line={num}::mixed conditional: "
                    f"{outside!r} sits outside the braces and is ignored. "
                    f"Put the whole condition inside a single expression."
                )
                bad += 1

        # 3. Every bash `run:` block parses as shell. A workflow is mostly shell
        #    pasted into YAML, and YAML validity says nothing about it.
        #
        #    ${{ }} is substituted before the shell ever sees it, so replace it
        #    with a bare token rather than letting it confuse bash.
        try:
            doc = yaml.safe_load(open(path)) or {}
        except Exception:
            continue
        for jobname, job in (doc.get("jobs") or {}).items():
            for n, step in enumerate(job.get("steps") or []):
                script = step.get("run")
                if not script:
                    continue
                shell = step.get("shell") or (job.get("defaults", {})
                                              .get("run", {}).get("shell")) or "bash"
                if shell not in ("bash", "sh", "bash -e {0}"):
                    continue
                stub = EXPR.sub("EXPR", script)
                proc = subprocess.run(["bash", "-n"], input=stub,
                                      text=True, capture_output=True)
                if proc.returncode != 0:
                    label = step.get("name") or f"step {n}"
                    msg = proc.stderr.strip().splitlines()[-1] if proc.stderr else "?"
                    print(f"::error file={path}::{jobname} / {label}: "
                          f"run block is not valid shell -- {msg}")
                    bad += 1

        print(f"ok   {path}")

    if bad:
        print(f"{bad} problem(s)")
        return 1
    print(f"{len(files)} workflow(s) valid, no mixed conditionals")
    return 0


if __name__ == "__main__":
    sys.exit(main())
