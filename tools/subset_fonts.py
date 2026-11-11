"""Rebuilds third_party/fonts/FiraSans-{Regular,SemiBold}.ttf (the kit's embedded UI fonts) from the
official Fira Sans TTFs (google/fonts ofl/firasans). Needs fontTools (py -3.10 has it).
Usage: py -3.10 tools/subset_fonts.py <dir with FiraSans-Regular.ttf, FiraSans-SemiBold.ttf, OFL.txt>"""
import pathlib, shutil, sys
from fontTools import subset

# Basic Latin, Latin-1 + Extended-A/B, spacing modifiers (U+02BC = Ukrainian apostrophe), Greek,
# Cyrillic + Supplement, General Punctuation, currency, letterlike (No sign, TM), number forms, arrows, U+FFFD.
UNICODES = '0020-007E,00A0-024F,02B0-02FF,0370-03FF,0400-052F,2000-206F,20A0-20CF,2100-218F,2190-21FF,FFFD'
# ImGui (stb_truetype) ignores hinting and does no shaping: drop hints, keep only GPOS kerning.
ARGS = ['--unicodes=' + UNICODES, '--layout-features=kern', '--no-hinting', '--drop-tables+=DSIG']

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(__file__).resolve().parent.parent / 'third_party' / 'fonts'
out.mkdir(parents=True, exist_ok=True)
for face in ('Regular', 'SemiBold'):
    name = f'FiraSans-{face}.ttf'
    subset.main([str(src / name), f'--output-file={out / name}', *ARGS])
    print(f'{name}: {(src / name).stat().st_size} -> {(out / name).stat().st_size} bytes')
shutil.copy(src / 'OFL.txt', out / 'OFL.txt')
