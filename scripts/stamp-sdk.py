#!/usr/bin/env python3
"""Raise the SDK version recorded in a thin arm64 iOS executable's LC_BUILD_VERSION.

UIKit picks layout behaviour (for example full-screen use on iPhone Duo) from the
SDK the main executable was linked against. Only the 4-byte sdk field is rewritten;
minos, platform, tool entries, load-command order and every other byte stay as is.
Any edit invalidates the code signature, so re-sign the app afterwards.
"""

import argparse
import pathlib
import shutil
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
HEADER_SIZE = 32
# struct build_version_command: cmd, cmdsize, platform, minos, sdk, ntools
BUILD_VERSION_SIZE = 24
SDK_FIELD = 16
FAT_MAGICS = {0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA}


def parse_version(text):
    parts = text.split(".")
    if not 2 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
        raise ValueError(f"invalid version {text!r}; expected MAJOR.MINOR[.PATCH]")
    major, minor, patch = (int(p) for p in parts + ["0"] * (3 - len(parts)))
    if major > 0xFFFF or minor > 0xFF or patch > 0xFF:
        raise ValueError(f"version {text!r} out of range")
    return major << 16 | minor << 8 | patch


def format_version(value):
    text = f"{value >> 16}.{value >> 8 & 0xFF}"
    return text + f".{value & 0xFF}" if value & 0xFF else text


def locate_sdk_field(path):
    """Return (file offset of the sdk field, platform, minos, sdk, ntools)."""
    with open(path, "rb") as f:
        head = f.read(HEADER_SIZE)
        if len(head) < HEADER_SIZE:
            raise ValueError("not a Mach-O file")
        (magic,) = struct.unpack_from(">I", head)
        if magic in FAT_MAGICS:
            raise ValueError("fat Mach-O is not supported; extract the arm64 slice")
        magic, cputype, _, filetype, ncmds, sizeofcmds = struct.unpack_from(
            "<IiIIII", head
        )
        if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
            raise ValueError("expected thin little-endian arm64 Mach-O")
        if filetype != MH_EXECUTE:
            raise ValueError("expected a main executable (MH_EXECUTE)")
        cmds = f.read(sizeofcmds)
    if len(cmds) != sizeofcmds:
        raise ValueError("truncated load commands")
    found = []
    pos = 0
    for _ in range(ncmds):
        if pos + 8 > sizeofcmds:
            raise ValueError("malformed load commands")
        cmd, size = struct.unpack_from("<II", cmds, pos)
        if size < 8 or size % 4 or pos + size > sizeofcmds:
            raise ValueError("malformed load commands")
        if cmd == LC_BUILD_VERSION:
            if size < BUILD_VERSION_SIZE:
                raise ValueError("malformed LC_BUILD_VERSION")
            platform, minos, sdk, ntools = struct.unpack_from("<IIII", cmds, pos + 8)
            if size != BUILD_VERSION_SIZE + 8 * ntools:
                raise ValueError("malformed LC_BUILD_VERSION")
            found.append((HEADER_SIZE + pos + SDK_FIELD, platform, minos, sdk, ntools))
        pos += size
    if len(found) != 1:
        raise ValueError(
            f"expected exactly one LC_BUILD_VERSION, found {len(found)} "
            "(LC_VERSION_MIN_* binaries are not supported)"
        )
    return found[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("executable", type=pathlib.Path)
    parser.add_argument("--sdk", default="27.1", help="target SDK (default: 27.1)")
    parser.add_argument(
        "-o", "--output", type=pathlib.Path, help="write a patched copy"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="report only; exit 1 if sdk is below target",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="allow lowering the SDK or non-iOS platforms",
    )
    args = parser.parse_args(argv)
    if args.check and args.output:
        parser.error("--check does not write; drop -o")
    try:
        target = parse_version(args.sdk)
        offset, platform, minos, sdk, _ = locate_sdk_field(args.executable)
    except (ValueError, OSError) as error:
        raise SystemExit(f"stamp-sdk: {args.executable}: {error}")
    old, new = format_version(sdk), format_version(target)
    if args.check:
        print(f"sdk {old} (target {new}, minos {format_version(minos)})")
        return 0 if sdk >= target else 1
    if platform != PLATFORM_IOS and not args.force:
        raise SystemExit(
            f"stamp-sdk: platform {platform} is not iOS (2); use --force to override"
        )
    if sdk > target and not args.force:
        print(f"sdk {old} is already above {new}; not lowering (use --force)")
        target = sdk
    destination = args.output or args.executable
    if args.output:
        shutil.copyfile(args.executable, args.output)
        shutil.copymode(args.executable, args.output)
    if target != sdk:
        with open(destination, "r+b") as f:
            f.seek(offset)
            f.write(struct.pack("<I", target))
    print(f"sdk {old} -> {format_version(target)}")
    if target != sdk:
        print(
            "note: the code signature is now invalid; re-sign the app "
            "(Sideloadly, AltStore etc. do this on install)",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
