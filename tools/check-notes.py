"""Checks that every ```zig block in docs/ZIG-0.17-NOTES.md appears verbatim in docs/notes_std.zig or
docs/notes_check.zig (which `zig build test` compiles and runs). Usage: py -3.12 tools/check-notes.py
Blocks that are build files (build.zig / build.zig.zon fragments) are exempt: they are verified by
building a consumer project, not by the test suite."""
import pathlib, re, sys

docs = pathlib.Path(__file__).resolve().parent.parent / 'docs'
md = (docs / 'ZIG-0.17-NOTES.md').read_text(encoding='utf-8')
src = (docs / 'notes_std.zig').read_text(encoding='utf-8') + (docs / 'notes_check.zig').read_text(encoding='utf-8')
blocks = re.findall(r'```zig\n(.*?)```', md, re.S)
bad = 0
for b in blocks:
    if b.startswith('.dependencies') or 'pub fn build(b: *std.Build)' in b:
        continue
    if b.strip() not in src:
        bad += 1
        print('NOT IN TESTS:\n' + b[:300] + '\n---')
print(f'{len(blocks)} zig blocks, {bad} out of sync')
sys.exit(1 if bad else 0)
