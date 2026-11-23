#!/usr/bin/env python3
"""Inspect an Android boot v4 image: header, kernel payload hash, payload region,
vbmeta placement, AVB footer. Optionally compare against an expected Image."""
import hashlib
import struct
import subprocess
import sys
import tempfile
import os

LZ4 = r'F:\114514\tools\lz4\lz4.exe'


def main():
    path = sys.argv[1]
    expect = sys.argv[2] if len(sys.argv) > 2 else None
    data = open(path, 'rb').read()
    print(f'file            : {path}')
    print(f'size            : {len(data)}')
    if data[:8] != b'ANDROID!':
        print('MAGIC BAD:', data[:8])
        return 1
    # boot header v3/v4: magic[8] kernel_size@8 ramdisk_size@12 os_version@16
    # header_size@20 reserved[4]@24 header_version@40 cmdline@44
    kernel_size = struct.unpack_from('<I', data, 8)[0]
    ramdisk_size = struct.unpack_from('<I', data, 12)[0]
    os_version = struct.unpack_from('<I', data, 16)[0]
    header_size = struct.unpack_from('<I', data, 20)[0]
    header_version = struct.unpack_from('<I', data, 40)[0]
    page_size = 4096
    print(f'header_version  : {header_version}  header_size={header_size} os_version=0x{os_version:08x}')
    print(f'page_size       : {page_size} (fixed for v3/v4)')
    print(f'kernel_size     : {kernel_size}')
    print(f'ramdisk_size    : {ramdisk_size}')

    koff = page_size
    kernel = data[koff:koff + kernel_size]
    print(f'kernel magic    : {kernel[:4].hex()}')
    tmp = os.path.join(tempfile.gettempdir(), '_k.lz4')
    outp = os.path.join(tempfile.gettempdir(), '_k.img')
    open(tmp, 'wb').write(kernel)
    r = subprocess.run([LZ4, '-d', '-f', tmp, outp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode == 0:
        raw = open(outp, 'rb').read()
        h = hashlib.sha256(raw).hexdigest()
        print(f'kernel decompressed: {len(raw)} bytes sha256={h}')
        if expect:
            print(f'expected Image     : sha256={expect}')
            print('KERNEL MATCH' if h.lower() == expect.lower() else '!! KERNEL MISMATCH')
        try:
            img = open(expected if expect else '', 'rb')
        except Exception:
            pass
    else:
        print('lz4 decompress FAILED')
    for p in (tmp, outp):
        try:
            os.remove(p)
        except OSError:
            pass

    # payload region: between kernel end and vbmeta
    vb_off = data.find(b'AVB0', koff + kernel_size)
    print(f'kernel end      : {koff + kernel_size}')
    print(f'vbmeta (AVB0)   : {vb_off}')
    if vb_off > 0:
        print(f'payload region  : {vb_off - (koff + kernel_size)} bytes')
    foot = data[-64:]
    if foot[:4] == b'AVBf':
        ver_major = struct.unpack_from('>I', foot, 4)[0]
        ver_minor = struct.unpack_from('>I', foot, 8)[0]
        orig = struct.unpack_from('>Q', foot, 12)[0]
        vbmeta_offset = struct.unpack_from('>Q', foot, 20)[0]
        vbmeta_size = struct.unpack_from('>Q', foot, 28)[0]
        print(f'footer          : AVBf v{ver_major}.{ver_minor} orig_size={orig} vbmeta_off={vbmeta_offset} vbmeta_size={vbmeta_size}')
        print('footer consistent:', 'YES' if (vbmeta_offset == vb_off or orig == vb_off) else 'CHECK MANUALLY')
    else:
        print('footer          : no AVBf', foot[:8].hex())
    return 0


if __name__ == '__main__':
    sys.exit(main())
