Fira Sans 4.203 (SIL Open Font License 1.1, see OFL.txt), subset for the MakeKit UI font.
  source:  https://github.com/google/fonts/tree/main/ofl/firasans  (FiraSans-Regular.ttf, FiraSans-SemiBold.ttf,
           OFL.txt; name table "Version 4.203"; fetched 2026-11-11)
  use:     Regular = body text (app.fonts.regular), SemiBold = titles (app.fonts.bold); embedded via embed.zig.
  subset:  py -3.10 tools/subset_fonts.py <dir with the original TTFs + OFL.txt>
           = pyftsubset --unicodes=0020-007E,00A0-024F,02B0-02FF,0370-03FF,0400-052F,2000-206F,20A0-20CF,
             2100-218F,2190-21FF,FFFD --layout-features=kern --no-hinting --drop-tables+=DSIG
           (Latin + Latin-1 + Ext-A/B, spacing modifiers, Greek, Cyrillic + Supplement, punctuation,
           currency, letterlike incl. No sign, number forms, arrows; hinting dropped, only GPOS kern kept;
           Fira has no U+FFFD). Characters outside the subset fall back to Segoe UI (merged at runtime).
  size:    457 KB -> 134 KB (Regular), 489 KB -> 134 KB (SemiBold); GPOS kern ~60 KB of each.
