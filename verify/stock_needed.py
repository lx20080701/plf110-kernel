#!/usr/bin/env python3
"""Completeness proof for one boot stage / one kernel build.

needed  = union(UND) of the .ko set that stock actually loads (from /proc/modules)
minus   = union(exports) of those same .ko files
provided= exported symbols of our Image (System.map: __ksymtab_<name>)
missing = needed - provided
"""
import os
import sys

sys.path.insert(0, r'F:\114514\tools')
from ko_symbols import ko_info


def load_loaded_names(path, prefix=''):
    names = []
    for line in open(path, 'r', errors='replace'):
        p = line.split()
        if not p:
            continue
        n = p[0]
        if prefix and not n.startswith(prefix):
            continue
        names.append(n)
    return names


def collect_files(roots):
    m = {}
    for root in roots:
        for dp, _d, fs in os.walk(root):
            for f in fs:
                if f.endswith('.ko'):
                    stem = f[:-3]
                    # kernel module names use '_' where filenames use '-'
                    for key in {stem, stem.replace('-', '_')}:
                        m.setdefault(key, []).append(os.path.join(dp, f))
    return m


def provided_from_map(path):
    s = set()
    for line in open(path, 'r', errors='replace'):
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
        s.add(short)
    return s


def main():
    loaded_txt, sysmap, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    roots = sys.argv[4:]
    names = load_loaded_names(loaded_txt)
    files = collect_files(roots)
    matched, unmatched = [], []
    for n in names:
        if n in files:
            matched.append(n)
        else:
            unmatched.append(n)

    needed = set()
    exported = set()
    per_module = {}
    for n in matched:
        for p in files[n]:
            und, exp = ko_info(p)
            needed |= und
            exported |= exp
            per_module.setdefault(n, set()).update(und)

    provided = provided_from_map(sysmap)
    need_kernel = needed - exported
    missing = need_kernel - provided

    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, 'needed_kernel.txt'), 'w').write('\n'.join(sorted(need_kernel)) + '\n')
    open(os.path.join(outdir, 'missing.txt'), 'w').write('\n'.join(sorted(missing)) + '\n')
    open(os.path.join(outdir, 'unmatched_modules.txt'), 'w').write('\n'.join(sorted(unmatched)) + '\n')
    open(os.path.join(outdir, 'per_module_missing.txt'), 'w').write(
        '\n'.join(f'{m}: ' + ','.join(sorted(v)) for m, v in sorted(per_module.items()) if False) + '\n')

    print(f'loaded modules      : {len(names)}')
    print(f'matched to files    : {len(matched)}   unmatched: {len(unmatched)}')
    print(f'UND (raw)           : {len(needed)}')
    print(f'exported by modules : {len(exported)}')
    print(f'needed from kernel  : {len(need_kernel)}')
    print(f'provided by kernel  : {len(provided)}')
    print(f'MISSING             : {len(missing)}')
    for n in sorted(missing)[:80]:
        print('  ', n)
    if unmatched:
        print('unmatched sample:', unmatched[:15])


if __name__ == '__main__':
    sys.exit(main())
