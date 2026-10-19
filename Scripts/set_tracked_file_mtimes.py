#!/usr/bin/env python3
"""Set each tracked regular file's mtime to a value derived from its content.

CI runs this after restoring a SwiftPM build cache; `.github/workflows/ci.yml` explains why.
"""

from __future__ import annotations

import hashlib
import os
import stat
import subprocess


def main() -> None:
    count = 0
    for raw in subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True).stdout.split(b"\0"):
        if not raw:
            continue
        path = raw.decode()
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            continue
        with open(path, "rb") as f:
            digest = int(hashlib.sha1(f.read()).hexdigest()[:15], 16)
        seconds = 1_000_000_000 + digest % 500_000_000
        nanoseconds = (digest >> 29) % 1_000_000_000
        os.utime(path, ns=(info.st_atime_ns, seconds * 1_000_000_000 + nanoseconds))
        count += 1
    print(f"set the mtime of {count} tracked files")


if __name__ == "__main__":
    main()
