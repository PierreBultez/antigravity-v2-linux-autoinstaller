"""Builds fake Antigravity archives and PNGs for tests/run.sh.

  make-fakes.py png OUT SIZE
  make-fakes.py archives SERVE_DIR BUILD_DIR
"""
import io
import json
import struct
import sys
import tarfile
import zlib
from pathlib import Path


def png(size: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    raw = b"".join(b"\x00" + b"\x80\x40\xff" * size for _ in range(size))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def asar(files: dict) -> bytes:
    """Minimal Electron asar archive (header pickle + concatenated files)."""
    offset, entries, blobs = 0, {}, []
    for name, data in files.items():
        entries[name] = {"size": len(data), "offset": str(offset)}
        blobs.append(data)
        offset += len(data)
    header = json.dumps({"files": entries}).encode()
    padded = header + b"\x00" * (-len(header) % 4)
    pickle = struct.pack("<II", len(padded) + 4, len(header)) + padded
    return struct.pack("<II", 4, len(pickle)) + pickle + b"".join(blobs)


def add(tar: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644) -> None:
    info = tarfile.TarInfo(name)
    info.size, info.mode = len(data), mode
    tar.addfile(info, io.BytesIO(data))


def desktop_archive(path: Path, version: str) -> None:
    top = "Antigravity-x64"
    with tarfile.open(path, "w:gz") as t:
        add(t, f"{top}/antigravity", f"#!/bin/sh\necho 'fake antigravity {version}'\n".encode(), 0o755)
        add(t, f"{top}/chrome-sandbox", b"\x7fELF", 0o755)
        add(t, f"{top}/resources/app.asar", asar({
            "package.json": json.dumps({"name": "antigravity", "version": version}).encode(),
            "icon.png": png(256),
        }))


def ide_archive(path: Path, version: str) -> None:
    top = "Antigravity IDE"
    with tarfile.open(path, "w:gz") as t:
        add(t, f"{top}/antigravity-ide", b"#!/bin/sh\necho 'fake ide'\n", 0o755)
        add(t, f"{top}/bin/antigravity-ide", b"#!/bin/sh\necho 'fake ide cli'\n", 0o755)
        add(t, f"{top}/resources/app/resources/linux/code.png", png(1024))
        add(t, f"{top}/resources/app/product.json", json.dumps({"ideVersion": version}).encode())


def main() -> None:
    if sys.argv[1] == "png":
        Path(sys.argv[2]).write_bytes(png(int(sys.argv[3])))
    elif sys.argv[1] == "archives":
        serve = Path(sys.argv[2])
        for version in ("1.0.0-11", "1.1.0-12"):
            d = serve / version / "linux-x64"
            d.mkdir(parents=True, exist_ok=True)
            desktop_archive(d / "Antigravity.tar.gz", version.split("-")[0])
        d = serve / "2.0.0-22" / "linux-x64"
        d.mkdir(parents=True, exist_ok=True)
        ide_archive(d / "Antigravity IDE.tar.gz", "2.0.0")


if __name__ == "__main__":
    main()
