#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile

MAX_ENTRIES = 10_000
MAX_BYTES = 2 * 1024 * 1024 * 1024
MAX_NESTING = 3
TIMEOUT_SECONDS = 120
ARCHIVE_SUFFIXES = (
    ".zip", ".apk", ".7z", ".rar", ".tar", ".tar.gz", ".tgz",
    ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
)


class LimitError(RuntimeError):
    pass


class Quota:
    def __init__(self) -> None:
        self.entries = 0
        self.bytes = 0

    def add(self, size: int) -> None:
        self.entries += 1
        self.bytes += size
        if self.entries > MAX_ENTRIES:
            raise LimitError("archive member limit exceeded")
        if self.bytes > MAX_BYTES:
            raise LimitError("archive size limit exceeded")


def controlled_name(name: str) -> PurePosixPath:
    normalized = name.replace("\\", "/")
    path = PurePosixPath(normalized)
    windows = PureWindowsPath(name)
    if (not normalized or "\x00" in normalized or path.is_absolute()
            or windows.is_absolute() or windows.drive
            or any(part in {"", ".", ".."} for part in path.parts)):
        raise LimitError(f"unsafe archive member path: {name!r}")
    return path


def remaining(deadline: float) -> float:
    value = deadline - time.monotonic()
    if value <= 0:
        raise LimitError("archive extraction timed out")
    return value


def copy_member(source, target: Path, expected: int, quota: Quota) -> None:
    quota.add(expected)
    target.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with target.open("xb") as output:
        while chunk := source.read(1024 * 1024):
            written += len(chunk)
            if written > expected:
                raise LimitError("archive member exceeds its declared size")
            output.write(chunk)
    if written != expected:
        raise LimitError("archive member size does not match its declaration")


def extract_zip(archive: Path, output: Path, quota: Quota, deadline: float) -> None:
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if any(item.flag_bits & 1 for item in entries):
            raise LimitError("encrypted archive members are not supported")
        for item in entries:
            remaining(deadline)
            relative = controlled_name(item.filename)
            mode = item.external_attr >> 16
            file_type = stat.S_IFMT(mode)
            if file_type and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise LimitError(f"archive member is not a regular file: {item.filename!r}")
            target = output.joinpath(*relative.parts)
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            with source.open(item) as payload:
                copy_member(payload, target, item.file_size, quota)


def extract_tar(archive: Path, output: Path, quota: Quota, deadline: float) -> None:
    with tarfile.open(archive, mode="r:*") as source:
        for item in source:
            remaining(deadline)
            relative = controlled_name(item.name)
            target = output.joinpath(*relative.parts)
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not item.isfile():
                raise LimitError(f"archive member is not a regular file: {item.name!r}")
            payload = source.extractfile(item)
            if payload is None:
                raise LimitError(f"archive member has no readable payload: {item.name!r}")
            with payload:
                copy_member(payload, target, item.size, quota)


def seven_zip_entries(archive: Path, deadline: float) -> list[dict[str, str]]:
    result = subprocess.run(
        ["7z", "l", "-slt", "--", str(archive)], capture_output=True, text=True,
        timeout=remaining(deadline), check=False,
    )
    if result.returncode != 0:
        raise LimitError("7z archive listing failed")
    body = result.stdout.split("----------", 1)
    if len(body) != 2:
        raise LimitError("7z archive listing is incomplete")
    records: list[dict[str, str]] = []
    for block in body[1].strip().split("\n\n"):
        record = {}
        for line in block.splitlines():
            key, separator, value = line.partition(" = ")
            if separator:
                record[key.strip()] = value.strip()
        if record.get("Path"):
            records.append(record)
    return records


def extract_7z(archive: Path, output: Path, quota: Quota, deadline: float) -> None:
    records = seven_zip_entries(archive, deadline)
    declared = 0
    files = 0
    for item in records:
        controlled_name(item["Path"])
        if item.get("Symbolic Link") or item.get("Hard Link"):
            raise LimitError("archive links are not supported")
        if item.get("Folder", "-") != "+":
            files += 1
            declared += int(item.get("Size") or 0)
    if quota.entries + files > MAX_ENTRIES or quota.bytes + declared > MAX_BYTES:
        raise LimitError("archive quota would be exceeded")
    result = subprocess.run(
        ["7z", "x", "-y", f"-o{output}", "--", str(archive)],
        capture_output=True, timeout=remaining(deadline), check=False,
    )
    if result.returncode != 0:
        raise LimitError("7z archive extraction failed")
    for base, directories, filenames in os.walk(output, topdown=True, followlinks=False):
        for name in directories:
            if Path(base, name).is_symlink():
                raise LimitError("archive links are not supported")
        for name in filenames:
            path = Path(base, name)
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode):
                raise LimitError("archive members must be regular files")
            quota.add(info.st_size)


def archive_type(path: Path) -> str | None:
    name = path.name.lower()
    if name.endswith((".zip", ".apk")):
        return "zip"
    if name.endswith((".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz")):
        return "tar"
    if name.endswith((".7z", ".rar")):
        return "7z"
    return None


def unpack_one(archive: Path, output: Path, quota: Quota, deadline: float) -> None:
    kind = archive_type(archive)
    if kind is None:
        raise LimitError(f"unsupported archive format: {archive.name}")
    output.mkdir(parents=True, exist_ok=False)
    if kind == "zip":
        extract_zip(archive, output, quota, deadline)
    elif kind == "tar":
        extract_tar(archive, output, quota, deadline)
    else:
        extract_7z(archive, output, quota, deadline)


def nested_archives(root: Path) -> list[Path]:
    return sorted(
        (path for path in root.rglob("*") if path.is_file() and archive_type(path)),
        key=lambda path: path.as_posix(),
    )


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: astra-unpack ARCHIVE OUTPUT_DIR", file=sys.stderr)
        return 2
    source_path = Path(sys.argv[1])
    if source_path.is_symlink():
        raise LimitError("archive input must not be a symbolic link")
    archive = source_path.resolve(strict=True)
    destination = Path(sys.argv[2]).resolve(strict=False)
    if not archive.is_file() or archive.is_symlink():
        raise LimitError("archive input must be a regular file")
    if destination.exists():
        raise LimitError("output directory must not already exist")
    destination.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + TIMEOUT_SECONDS
    quota = Quota()
    staging = Path(tempfile.mkdtemp(prefix=".astra-unpack-", dir=destination.parent))
    payload = staging / "payload"
    try:
        unpack_one(archive, payload, quota, deadline)
        frontier = nested_archives(payload)
        for depth in range(1, MAX_NESTING + 1):
            if not frontier:
                break
            next_frontier: list[Path] = []
            for nested in frontier:
                output = nested.with_name(nested.name + ".unpacked")
                unpack_one(nested, output, quota, deadline)
                next_frontier.extend(nested_archives(output))
            frontier = next_frontier
        if frontier:
            raise LimitError(f"nested archive depth exceeds {MAX_NESTING}")
        payload.replace(destination)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    shutil.rmtree(staging, ignore_errors=True)
    print(f"extracted entries={quota.entries} bytes={quota.bytes} output={destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (LimitError, OSError, tarfile.TarError, zipfile.BadZipFile,
            subprocess.SubprocessError) as exc:
        print(f"astra-unpack: {exc}", file=sys.stderr)
        raise SystemExit(1)
