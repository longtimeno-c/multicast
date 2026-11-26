#!/usr/bin/python3 -I
"""Give the Mac app's Debug stub executable the same Mach-O UUID in every checkout.

Why: macOS Local Network privacy identifies an app by its main executable's UUID (TN3179:
"Local network privacy uses your main executable UUID as part of its implementation"). With
ENABLE_DEBUG_DYLIB, the main executable of a Debug build is a small stub and the app's code is in
Multicast.debug.dylib, so the stub (and its UUID) stays the same from build to build, and the
Local Network grant survives rebuilds. But Xcode links the stub with an absolute
`-rpath <BUILT_PRODUCTS_DIR>/PackageFrameworks`, so every checkout and worktree produces a
different stub, a different UUID, and so needs its own grant.

What: after linking (Xcode code-signs afterwards), for a Debug stub only:
1. delete that absolute PackageFrameworks rpath (the directory holds nothing this app loads);
2. set LC_UUID to a name-based UUID made from the bundle id and what Xcode builds the stub from
   (Xcode build, architectures, deployment target, configuration). Same in every checkout; new
   when the stub really changes.

Usage: stable-debug-uuid.py <path to main executable> <bundle id>
"""
import hashlib
import os
import struct
import subprocess
import sys
import uuid

MH_MAGIC_64 = 0xFEEDFACF
LC_UUID = 0x1B
LC_RPATH = 0x8000001C
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_64 = 0x19


def load_commands(data):
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit("not a thin 64-bit little-endian Mach-O")
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        yield cmd, offset, size
        offset += size


def rpaths(data):
    out = []
    for cmd, off, size in load_commands(data):
        if cmd == LC_RPATH:
            (name_off,) = struct.unpack_from("<I", data, off + 8)
            raw = data[off + name_off: off + size]
            out.append(raw.split(b"\0", 1)[0].decode())
    return out


def main():
    exe, bundle_id = sys.argv[1], sys.argv[2]
    debug_dylib = os.path.join(os.path.dirname(exe), os.path.basename(exe) + ".debug.dylib")
    if not os.path.exists(debug_dylib):
        print("stable-debug-uuid: no debug dylib, leaving the executable as linked")
        return
    with open(exe, "rb") as f:
        data = f.read()
    for path in rpaths(data):
        if os.path.isabs(path) and path.endswith("/PackageFrameworks"):
            subprocess.run(["xcrun", "install_name_tool", "-delete_rpath", path, exe], check=True)
    with open(exe, "rb") as f:
        original = f.read()
    data = bytearray(original)
    stable = uuid.uuid5(uuid.NAMESPACE_URL, "multicast-debug-stub:" + fingerprint(data, bundle_id))
    for cmd, off, _ in load_commands(data):
        if cmd == LC_UUID:
            data[off + 8: off + 24] = stable.bytes
    if bytes(data) != original:
        with open(exe, "r+b") as f:
            f.write(data)
    print(f"stable-debug-uuid: {str(stable).upper()}")


def fingerprint(data, bundle_id):
    """What the stub is made from. Xcode generates it; its bytes depend on the Xcode build, the
    architecture and the deployment target, and on nothing in this project's sources (the app's
    code is in the debug dylib). The stub's own bytes can't be used: the absolute rpath shifts
    its sections, so they differ between checkouts. A new Xcode or deployment target gives a new
    UUID, as the linker would."""
    if not any(cmd == LC_UUID for cmd, _, _ in load_commands(data)):
        raise SystemExit("stable-debug-uuid: executable has no LC_UUID")
    parts = [bundle_id] + [os.environ.get(k, "") for k in
                           ("XCODE_PRODUCT_BUILD_VERSION", "ARCHS", "MACOSX_DEPLOYMENT_TARGET", "CONFIGURATION")]
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()

if __name__ == "__main__":
    main()
