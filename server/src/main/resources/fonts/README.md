# Full-glyph PDF font profile

`NotoSansSCFullPdf.ttf` is derived reproducibly from the unchanged shared
`assets/fonts/NotoSansSCFull.ttf` (SHA-256
`a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`).
It is a complete font, with all 31,036 glyphs and all 30,890 Unicode base
character mappings. It is not a character subset. All outline, variation,
layout, horizontal/vertical metric, name, and license tables remain byte for
byte identical. The manifest records every preserved table and cmap digest.

FontBox 3.0.8 does not implement cmap format 14 and logs a warning while
ignoring it. This backend profile removes only the source's 147-byte format
14 Unicode variation-sequence (UVS) subtable and its encoding record. The
other five cmap records, including both full-repertoire format 12 records,
retain exactly the original bytes. Table offsets stay fixed; the former cmap
allocation ends in zero padding, and directory/font checksums are recomputed.
No logger levels or warning filters are changed.

UVS selects a variant glyph for a base character plus variation selector;
it is separate from the ordinary Unicode-to-glyph mapping. This profile does
not add UVS support. FontBox already ignored the original UVS table, so its
existing PDF glyph-selection behavior is preserved. The untouched original
font remains available to Flutter and for a future PDF engine that supports
UVS. Rare characters supported by the original, including supplementary-plane
CJK characters, remain supported; characters absent from the original are
not invented by this profile.

The source font's name table is preserved, including its copyright notice:
`(c) 2014-2021 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'.`
Its primary names are `Noto Sans SC Thin` / `NotoSansSC-Thin`, and do not use
the reserved primary name `Source`. The derivative remains under SIL Open
Font License 1.1. The unchanged `assets/fonts/OFL.txt` is packaged beside it
as `/fonts/OFL.txt`; the source font's copyright and license metadata are also
retained. No upstream endorsement is implied.

Rebuild or verify from the repository root with Python's standard library:

```sh
python scripts/build_pdf_font_profile.py
python scripts/build_pdf_font_profile.py --check
```

The generator refuses an unexpected source hash and verifies complete base
mapping equality, all supported cmap bytes, every other table, original table
offsets, glyph count, and the sfnt checksum. `PdfFontProfileTest` independently
checks those properties and real PDF extraction, supplementary CJK rendering,
exact amounts, embedding, encryption, and the absence of FontBox WARN/ERROR.

References: [OpenType cmap specification](https://learn.microsoft.com/en-us/typography/opentype/spec/cmap)
and the [FontBox 3.0.8 cmap reader](https://github.com/apache/pdfbox/blob/3.0.8/fontbox/src/main/java/org/apache/fontbox/ttf/CmapSubtable.java).
