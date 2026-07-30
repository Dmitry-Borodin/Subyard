#!/usr/bin/env python3
"""Fail-closed verification for a full Hermes backup archive."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile


def fail(message: str) -> None:
    raise SystemExit(f"hermes backup verify: {message}")


if len(sys.argv) not in {2, 3}:
    fail("usage: verify-backup.py ZIP [SHA256]")

archive = Path(sys.argv[1])
try:
    info = archive.lstat()
except OSError as exc:
    fail(str(exc))
if not stat.S_ISREG(info.st_mode) or archive.is_symlink() or info.st_size <= 0:
    fail("archive must be a non-empty regular file")

digest = hashlib.sha256()
with archive.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
actual_sha = digest.hexdigest()
if len(sys.argv) == 3 and actual_sha != sys.argv[2].lower():
    fail("SHA-256 mismatch")

try:
    with zipfile.ZipFile(archive) as backup:
        names = backup.namelist()
        if not names:
            fail("archive is empty")
        for raw in names:
            if "\\" in raw:
                fail("archive contains a non-portable path")
            path = PurePosixPath(raw)
            if path.is_absolute() or ".." in path.parts:
                fail("archive contains an unsafe path")
        corrupt = backup.testzip()
        if corrupt:
            fail("CRC failure")
except (OSError, zipfile.BadZipFile) as exc:
    fail(str(exc))

basenames = {PurePosixPath(name).name for name in names}
if not basenames.intersection({"config.yaml", ".env", "state.db"}):
    fail("archive has no Hermes state marker")
if ".serve.env" not in basenames:
    fail("archive omitted the stable dashboard session token")

print(f"sha256={actual_sha}")
print(f"size={info.st_size}")
