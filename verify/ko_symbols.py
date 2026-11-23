#!/usr/bin/env python3
"""Stock vendor modules -> required kernel symbols; compare with our build's
export table (System.map __ksymtab_* labels).

needed_kernel = union(UND symbols of every .ko) - union(exports of every .ko)
provided      = exported symbols of our Image (System.map: __ksymtab_<name>)
missing       = needed_kernel - provided
"""
import os
import re
import struct
import sys

SHT_SYMTAB = 2
SHT_DYNSYM = 11


def sections(data):
    end = '<' if data[5] == 1 else '>'
    e_shoff = struct.unpack_from(end + 'Q', data, 0x28)[0]
    e_shentsize = struct.unpack_from(end + 'H', data, 0x3A)[0]
    e_shnum = struct.unpack_from(end + 'H', data, 0x3C)[0]
    e_shstrndx = struct.unpack_from(end + 'H', data, 0x3E)[0]

    def sh(i):
        return struct.unpack_from(end + 'IIQQQQIIQQ', data, e_shoff + i * e_shentsize)

    shstr = sh(e_shstrndx)[4]

    def sname(off):
        o = shstr + off
        return data[o:data.index(b'\0', o)].decode('latin1')

    out = []
    for i in range(e_shnum):
        s = sh(i)
        out.append({'name': sname(s[0]), 'type': s[1], 'offset': s[4], 'size': s[5], 'link': s[6], 'entsize': s[9]})
    return out, end


def sym_names(data, sec, end, strtab_off, want_undef=None, want_defined=None):
    """want_undef / want_defined: which symbols to return."""
    res = set()
    entsize = sec['entsize'] or 24
    n = sec['size'] // entsize
    for k in range(n):
        base = sec['offset'] + k * entsize
        if base + 24 > len(data):
            break
        name_off = struct.unpack_from(end + 'I', data, base)[0]
        info = data[base + 4]
        shndx = struct.unpack_from(end + 'H', data, base + 6)[0]
        if name_off == 0:
            continue
        o = strtab_off + name_off
        try:
            name = data[o:data.index(b'\0', o)].decode('latin1')
        except ValueError:
            continue
        if not name:
            continue
        if want_undef and shndx == 0:
            res.add(name)
        if want_defined and shndx != 0 and (info & 0xF) in (1, 2):  # OBJECT / FUNC
            res.add(name)
    return res


def ko_info(path):
    data = open(path, 'rb').read()
    if data[:4] != b'\x7fELF':
        return set(), set()
    secs, end = sections(data)
    byidx = secs
    und = set()
    defined = set()
    for i, s in enumerate(byidx):
        if s['type'] in (SHT_SYMTAB,):
            strtab_off = byidx[s['link']]['offset']
            und |= sym_names(data, s, end, strtab_off, want_undef=True)
            defined |= sym_names(data, s, end, strtab_off, want_defined=True)
    # exported symbols: names live in __ksymtab_strings (per-symbol rela sections
    # only exist for a few entries, so the strings section is the reliable source)
    exports = set()
    for s in byidx:
        n = s['name']
        m = re.match(r'^\.rela___ksymtab(?:_gpl)?\+(.+)$', n)
        if m:
            exports.add(m.group(1))
        if n == '__ksymtab_strings' or n.endswith('__ksymtab_strings'):
            blob = data[s['offset']:s['offset'] + s['size']]
            for part in blob.split(b'\0'):
                if part:
                    exports.add(part.decode('latin1'))
    return und, exports


def main():
    modroot = sys.argv[1]
    sysmap = sys.argv[2]
    outdir = sys.argv[3] if len(sys.argv) > 3 else '.'

    needed_all = set()
    provided_by_modules = set()
    exports_of = {}
    files = 0
    for root, _dirs, names in os.walk(modroot):
        for nm in names:
            if not nm.endswith('.ko'):
                continue
            p = os.path.join(root, nm)
            files += 1
            try:
                und, exp = ko_info(p)
            except Exception as e:
                print(f'!! {nm}: {e}', file=sys.stderr)
                continue
            needed_all |= und
            provided_by_modules |= exp
            exports_of[nm] = exp

    provided = set()
    for line in open(sysmap, 'r', errors='replace'):
        p = line.split()
        if len(p) < 3:
            continue
        n = p[2]
        if not n.startswith('__ksymtab_'):
            continue
        short = n[len('__ksymtab_'):]
        if short in ('strings', 'gpl', 'gpl_strings'):
            continue
        if short.startswith('__ksymtab') or short.startswith('__start_') or short.startswith('__stop_'):
            continue
        provided.add(short)

    needed_kernel = needed_all - provided_by_modules
    missing = needed_kernel - provided
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, 'needed_raw.txt'), 'w').write('\n'.join(sorted(needed_all)) + '\n')
    open(os.path.join(outdir, 'needed_kernel.txt'), 'w').write('\n'.join(sorted(needed_kernel)) + '\n')
    open(os.path.join(outdir, 'module_exports.txt'), 'w').write('\n'.join(sorted(provided_by_modules)) + '\n')
    open(os.path.join(outdir, 'provided.txt'), 'w').write('\n'.join(sorted(provided)) + '\n')
    open(os.path.join(outdir, 'missing.txt'), 'w').write('\n'.join(sorted(missing)) + '\n')

    print(f'ko files           : {files}')
    print(f'UND symbols (raw)  : {len(needed_all)}')
    print(f'exported by modules: {len(provided_by_modules)}')
    print(f'needed from kernel : {len(needed_kernel)}')
    print(f'provided by kernel : {len(provided)}')
    print(f'MISSING            : {len(missing)}')
    for n in sorted(missing):
        print('  ', n)


if __name__ == '__main__':
    sys.exit(main())
