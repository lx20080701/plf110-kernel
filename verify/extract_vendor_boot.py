#!/usr/bin/env python3
"""Extract modules from an Android vendor_boot.img (header v3/v4)."""
import os
import struct
import subprocess
import sys
import gzip
import io

LZ4 = r'F:\114514\tools\lz4\lz4.exe'


def cpio_names(blob):
    """Return list of (name, data) from newc cpio."""
    out = []
    i = 0
    while True:
        if blob[i:i + 6] != b'070701':
            if blob[i:i + 6] == b'070702':
                pass
            else:
                # try to resync
                j = blob.find(b'070701', i)
                if j < 0:
                    break
                i = j
        hdr = blob[i:i + 110]
        if len(hdr) < 110:
            break
        fields = [int(hdr[6 + k * 8: 14 + k * 8], 16) for k in range(13)]
        namesize = fields[11]
        filesize = fields[6]
        name = blob[i + 110: i + 110 + namesize - 1].decode('latin1')
        i += 110 + namesize
        i = (i + 3) & ~3
        data = blob[i:i + filesize]
        i += filesize
        i = (i + 3) & ~3
        if name == 'TRAILER!!!':
            break
        out.append((name, data))
    return out


def main():
    img = sys.argv[1]
    outdir = sys.argv[2]
    data = open(img, 'rb').read()
    if data[:8] not in (b'ANDROID!', b'VNDRBOOT'):
        raise SystemExit(f'not an android/vendor_boot image: {data[:8]!r}')
    header_version, page_size = struct.unpack_from('<II', data, 8)
    ramdisk_size = struct.unpack_from('<I', data, 24)[0]
    print(f'header_version={header_version} page_size={page_size} vendor_ramdisk_size={ramdisk_size}')

    off = page_size
    rd = data[off:off + ramdisk_size]
    os.makedirs(outdir, exist_ok=True)
    raw = None
    if rd[:4] == b'\x02\x21\x4c\x18':
        print('compression: lz4 legacy')
        tmp_in = os.path.join(outdir, '_rd.lz4')
        tmp_out = os.path.join(outdir, '_rd.cpio')
        open(tmp_in, 'wb').write(rd)
        subprocess.run([LZ4, '-d', '-f', tmp_in, tmp_out], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raw = open(tmp_out, 'rb').read()
        os.remove(tmp_in)
        os.remove(tmp_out)
    elif rd[:2] == b'\x1f\x8b':
        print('compression: gzip')
        raw = gzip.decompress(rd)
    elif rd[:6] == b'070701':
        print('compression: none (cpio)')
        raw = rd
    else:
        print('unknown compression, magic:', rd[:8].hex())
        return 1

    entries = cpio_names(raw)
    nmod = 0
    for name, blob in entries:
        if not name.endswith('.ko'):
            continue
        rel = name.lstrip('/').replace('../', '')
        dst = os.path.join(outdir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, 'wb').write(blob)
        nmod += 1
    print(f'cpio entries={len(entries)} modules={nmod}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
