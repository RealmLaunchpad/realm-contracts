#!/usr/bin/env python3
"""Fails if a taxable token and its dividend extension disagree on storage layout.

The extension is `delegatecall`ed with the token's storage, so every slot it writes has to be the
slot the token reads. Both sides derive their layout from a shared venue base and neither adds
state, so they cannot drift by accident - but "cannot" is worth checking, because the failure mode
is a live clone writing round state over its tax config, with no migration from it.

TRANSIENT slots are checked too, and for the same reason: `delegatecall` shares `tload`/`tstore`
space exactly as it shares storage, so a reordering of `dividendLocked` / `_inSwap` between the two
sides would have the extension taking the wrong reentrancy lock.
"""

import json
import os
import pathlib
import subprocess
import sys

OUT = pathlib.Path("out-layout")

PAIRS = [
    ("LivoTaxableTokenUniV2", "LivoDividendLogicUniV2"),
    ("LivoTaxableTokenUniV4", "LivoDividendLogicUniV4"),
]


def build():
    # The default profile does not emit layouts; `layout` does, into its own `out` dir.
    r = subprocess.run(
        ["forge", "build", "--skip", "test", "--skip", "script"],
        capture_output=True, text=True,
        env={**os.environ, "FOUNDRY_PROFILE": "layout"},
    )
    if r.returncode != 0:
        sys.exit(r.stdout + r.stderr)


def artifact(contract):
    # Every contract here lives in a file of its own name, which is what forge keys artifacts by.
    path = OUT / f"{contract}.sol" / f"{contract}.json"
    if not path.exists():
        sys.exit(f"no artifact at {path} - did {contract} get renamed or moved?")
    return json.loads(path.read_text())


def slots(layout):
    # `contract` and `astId` name where a variable was declared, which legitimately differs.
    return [(e["label"], e["slot"], e["offset"], e["type"]) for e in (layout or {}).get("storage", [])]


def layouts(contract):
    a = artifact(contract)
    return slots(a.get("storageLayout")), slots(a.get("transientStorageLayout"))


def compare(kind, token, extension, a, b):
    if a == b:
        print(f"ok   {kind:9} {token} == {extension}  ({len(a)} entries)")
        return False
    print(f"FAIL {kind:9} {token} != {extension}")
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else None
        y = b[i] if i < len(b) else None
        if x != y:
            print(f"       {token}: {x}\n       {extension}: {y}")
    return True


def main():
    build()
    failed = False
    for token, extension in PAIRS:
        (ta, tt), (ea, et) = layouts(token), layouts(extension)
        failed |= compare("storage", token, extension, ta, ea)
        failed |= compare("transient", token, extension, tt, et)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
