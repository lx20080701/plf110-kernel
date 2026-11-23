#!/usr/bin/env python3
"""Pre-flight kABI check: compare built kernel exported CRCs with the CRCs that
the device's stock vendor modules expect (parsed from their __versions section).

Why: stock vendor modules are built with MODVERSIONS, so the kernel checks the
CRC of every symbol they import. `module_layout` is the big one: its CRC is the
genksyms CRC of a function taking `struct module *` etc., so ANY config option
that changes struct module's layout (CONFIG_KUNIT, CONFIG_DEBUG_INFO_BTF_MODULES,
...) changes it and every vendor module fails with:
    "disagrees about version of symbol module_layout" -> Exec format error

Usage:
    check_kabi.py <vmlinux.symvers> <ref.ko> [<ref2.ko> ...]
"""
import struct
import sys


def parse_symvers(path):
    """vmlinux.symvers lines: 0x<CRC>\t<symbol>\t<module>\t<export-type>"""
    out = {}
    with open(path, 'r', errors='replace') as f:
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 2:
                continue
            try:
                crc = int(parts[0], 16)
            except ValueError:
                continue
            out.setdefault(parts[1], crc)
    return out


def parse_versions(ko_path):
    """Return {symbol: expected_crc} from an ELF .ko __versions section."""
    data = open(ko_path, 'rb').read()
    if data[:4] != b'\x7fELF':
        raise ValueError(f'{ko_path}: not an ELF file')
    if data[4] != 2:  # ELFCLASS64
        raise ValueError(f'{ko_path}: only 64-bit supported')
    end = '<' if data[5] == 1 else '>'
    e_shoff = struct.unpack_from(end + 'Q', data, 0x28)[0]
    e_shentsize = struct.unpack_from(end + 'H', data, 0x3A)[0]
    e_shnum = struct.unpack_from(end + 'H', data, 0x3C)[0]
    e_shstrndx = struct.unpack_from(end + 'H', data, 0x3E)[0]

    def sh(i):
        return struct.unpack_from(end + 'IIQQQQIIQQ', data, e_shoff + i * e_shentsize)

    shstr_off = sh(e_shstrndx)[4]

    def sec_name(idx):
        o = shstr_off + idx
        e = data.index(b'\0', o)
        return data[o:e].decode('latin1')

    secs = {sec_name(sh(i)[0]): i for i in range(e_shnum)}
    if '__versions' not in secs:
        raise ValueError(f'{ko_path}: no __versions section')
    i = secs['__versions']
    off, size = sh(i)[4], sh(i)[5]
    # struct modversion_info { unsigned long crc; char name[MODULE_NAME_LEN]; } = 64B
    ent = 64
    result = {}
    for k in range(size // ent):
        base = off + k * ent
        crc = struct.unpack_from(end + 'Q', data, base)[0]
        name = data[base + 8: base + ent].split(b'\0')[0].decode('latin1')
        result[name] = crc
    return result


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    symvers = parse_symvers(sys.argv[1])
    print(f'kernel exports in symvers: {len(symvers)}')

    total_ok = total_bad = total_missing = 0
    module_layout_ok = True
    for ko in sys.argv[2:]:
        try:
            expected = parse_versions(ko)
        except Exception as exc:  # noqa: BLE001
            print(f'!! {ko}: {exc}')
            continue
        print(f'\n== {ko} : {len(expected)} imported symbols ==')
        bad = []
        for name, want in sorted(expected.items()):
            got = symvers.get(name)
            if got is None:
                total_missing += 1
                if name == 'module_layout':
                    module_layout_ok = False
                    print(f'  MISSING module_layout (kernel does not export it?)')
                continue
            if (got & 0xFFFFFFFF) == (want & 0xFFFFFFFF):
                total_ok += 1
            else:
                total_bad += 1
                if name == 'module_layout':
                    module_layout_ok = False
                bad.append((name, want, got))
        for name, want, got in bad:
            print(f'  MISMATCH {name}: module expects 0x{want & 0xFFFFFFFF:08x}, '
                  f'kernel has 0x{got & 0xFFFFFFFF:08x}')
        print(f'  -> ok={sum(1 for n, w in expected.items() if symvers.get(n) is not None and (symvers[n] & 0xFFFFFFFF) == (w & 0xFFFFFFFF))}'
              f' mismatch={len(bad)} missing={sum(1 for n in expected if n not in symvers)}')

    print(f'\n==== kABI summary: ok={total_ok} mismatch={total_bad} missing={total_missing} ====')
    if module_layout_ok and total_bad == 0:
        print('==== RESULT: PASS - stock vendor modules should load ====')
        return 0
    print('==== RESULT: FAIL - stock vendor modules will be rejected ====')
    return 1


if __name__ == '__main__':
    sys.exit(main())
