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
3. if the stub was not relinked this build but already signed by Xcode (the first build after
   adding this phase), re-sign the bundle with the same identity, keeping its entitlements and
   flags, because Xcode won't sign it again.

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
        already_signed = signed_by_xcode(exe)
        with open(exe, "r+b") as f:
            f.write(data)
        if already_signed:
            # The stub wasn't relinked this build (e.g. the first build with this phase), so
            # Xcode signed it earlier and won't sign it again: re-sign the bundle the same way.
            resign()
    print(f"stable-debug-uuid: {str(stable).upper()}")


def resign():
    bundle = os.environ["CODESIGNING_FOLDER_PATH"]
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none",
                    "--preserve-metadata=identifier,entitlements,flags,runtime", bundle], check=True)
    print(f"stable-debug-uuid: re-signed {os.path.basename(bundle)}")


def signed_by_xcode(exe):
    """Whether the executable already carries a real signature (Xcode signed it in an earlier
    build), rather than none or the linker's ad hoc one."""
    r = subprocess.run(["codesign", "-dv", exe], capture_output=True, text=True)
    return r.returncode == 0 and "linker-signed" not in r.stderr


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
