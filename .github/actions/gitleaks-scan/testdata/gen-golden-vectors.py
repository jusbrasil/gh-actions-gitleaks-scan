#!/usr/bin/env python3
"""Generates golden secret_sha256 vectors independently of derive-findings.sh.
Run once to (re)produce testdata/golden-vectors.tsv; never invoked by CI.
Writes the secret as base64 so a literal newline/tab in a case can't corrupt
the TSV's line structure."""
import base64
import hashlib

CASES = [
    ("simple", "hunter2"),
    ("trailing_newline", "hunter2\n"),
    ("utf8", "sëcrét-válüé"),
    ("double_quotes", 'value with "quotes" inside'),
]

with open("golden-vectors.tsv", "w") as f:
    for name, secret in CASES:
        secret_b64 = base64.b64encode(secret.encode("utf-8")).decode("ascii")
        digest = hashlib.sha256(secret.encode("utf-8")).hexdigest()
        f.write(f"{name}\t{secret_b64}\t{digest}\n")
