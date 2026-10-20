#!/usr/bin/env python3
"""Build the backend PDF cmap profile without changing glyphs or metrics.

FontBox 3.0.x does not consume cmap format 14. Only that Unicode-variation
subtable is removed; all base-character maps and every other sfnt table are
copied byte for byte. The shared Flutter font remains the canonical source.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct

SOURCE_SHA256 = "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da"
FONT_CHECKSUM = 0xB1B0AFBA


def checksum(data: bytes) -> int:
    padded = data + b"\0" * (-len(data) % 4)
    return sum(value[0] for value in struct.iter_unpack(">I", padded)) & 0xFFFFFFFF


def tables(data: bytes) -> dict[str, tuple[int, int, int]]:
    if len(data) < 12 or data[:4] != b"\0\1\0\0":
        raise ValueError("expected a complete TrueType sfnt source")
    count = struct.unpack_from(">H", data, 4)[0]
    if 12 + count * 16 > len(data):
        raise ValueError("truncated sfnt directory")
    result = {}
    for index in range(count):
        entry = 12 + index * 16
        raw_tag, recorded, offset, length = struct.unpack_from(">4sIII", data, entry)
        tag = raw_tag.decode("ascii")
        if tag in result or offset + length > len(data):
            raise ValueError("invalid or duplicate sfnt table " + tag)
        body = data[offset:offset + length]
        if tag == "head":
            body = body[:8] + b"\0" * 4 + body[12:]
        if checksum(body) != recorded:
            raise ValueError("source table checksum mismatch: " + tag)
        result[tag] = (entry, offset, length)
    return result


def cmap_records(cmap: bytes) -> list[tuple[int, int, int, bytes]]:
    version, count = struct.unpack_from(">HH", cmap)
    if version != 0 or 4 + count * 8 > len(cmap):
        raise ValueError("invalid cmap directory")
    result = []
    for index in range(count):
        platform, encoding, offset = struct.unpack_from(">HHI", cmap, 4 + index * 8)
        if offset < 4 + count * 8 or offset + 4 > len(cmap):
            raise ValueError("invalid cmap subtable offset")
        form = struct.unpack_from(">H", cmap, offset)[0]
        if form in (0, 2, 4, 6):
            length = struct.unpack_from(">H", cmap, offset + 2)[0]
        elif form in (8, 10, 12, 13):
            length = struct.unpack_from(">I", cmap, offset + 4)[0]
        elif form == 14:
            length = struct.unpack_from(">I", cmap, offset + 2)[0]
        else:
            raise ValueError("unreviewed cmap format " + str(form))
        if length < 4 or offset + length > len(cmap):
            raise ValueError("truncated cmap subtable")
        result.append((platform, encoding, form, cmap[offset:offset + length]))
    return result


def base_mappings(records: list[tuple[int, int, int, bytes]]) -> dict[int, int]:
    full_maps = []
    for platform, encoding, form, body in records:
        if form != 12 or (platform, encoding) not in ((0, 4), (3, 10)):
            continue
        mapping = {}
        groups = struct.unpack_from(">I", body, 12)[0]
        if 16 + groups * 12 != len(body):
            raise ValueError("invalid format 12 group count")
        for index in range(groups):
            start, end, first_glyph = struct.unpack_from(">III", body, 16 + index * 12)
            if start > end or end > 0x10FFFF:
                raise ValueError("invalid Unicode group")
            for point in range(start, end + 1):
                mapping[point] = first_glyph + point - start
        full_maps.append(mapping)
    if not full_maps or any(mapping != full_maps[0] for mapping in full_maps):
        raise ValueError("Unicode full-repertoire mappings disagree")
    return {point: glyph for point, glyph in full_maps[0].items() if glyph != 0}


def build_profile(source: bytes) -> tuple[bytes, dict]:
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("source font changed; review glyph, cmap and license provenance first")
    if checksum(source) != FONT_CHECKSUM:
        raise ValueError("invalid source font checksum")
    directory = tables(source)
    entry, cmap_offset, cmap_length = directory["cmap"]
    records = cmap_records(source[cmap_offset:cmap_offset + cmap_length])
    removed = [record for record in records if record[2] == 14]
    kept = [record for record in records if record[2] != 14]
    if len(removed) != 1 or removed[0][:3] != (0, 5, 14):
        raise ValueError("expected exactly the reviewed Unicode variation subtable")
    new_cmap = bytearray(struct.pack(">HH", 0, len(kept)) + b"\0" * (8 * len(kept)))
    offsets = {}
    for index, (platform, encoding, _, body) in enumerate(kept):
        if body not in offsets:
            new_cmap.extend(b"\0" * (-len(new_cmap) % 4))
            offsets[body] = len(new_cmap)
            new_cmap.extend(body)
        struct.pack_into(">HHI", new_cmap, 4 + index * 8, platform, encoding, offsets[body])
    if len(new_cmap) > cmap_length:
        raise ValueError("profile must fit the original cmap allocation")
    # Keep every other table's original file offset. Unused cmap allocation is
    # zero padding, so even outline offsets and the sfnt directory stay stable.
    output = bytearray(source)
    output[cmap_offset:cmap_offset + cmap_length] = new_cmap + b"\0" * (cmap_length - len(new_cmap))
    struct.pack_into(">I", output, entry + 4, checksum(new_cmap))
    struct.pack_into(">I", output, entry + 12, len(new_cmap))
    head_offset = directory["head"][1]
    struct.pack_into(">I", output, head_offset + 8, 0)
    struct.pack_into(">I", output, head_offset + 8, (FONT_CHECKSUM - checksum(output)) & 0xFFFFFFFF)
    result = bytes(output)
    after = tables(result)
    if checksum(result) != FONT_CHECKSUM or directory.keys() != after.keys():
        raise ValueError("invalid derived sfnt checksum or table inventory")
    unchanged = {}
    for tag, (_, offset, length) in directory.items():
        if tag in ("cmap", "head"):
            continue
        if after[tag][1:] != (offset, length) or source[offset:offset + length] != result[offset:offset + length]:
            raise ValueError("profile changed preserved table " + tag)
        unchanged[tag] = hashlib.sha256(source[offset:offset + length]).hexdigest()
    if source[head_offset:head_offset + 8] != result[head_offset:head_offset + 8] or source[head_offset + 12:head_offset + directory["head"][2]] != result[head_offset + 12:head_offset + directory["head"][2]]:
        raise ValueError("profile changed head metrics")
    after_records = cmap_records(bytes(new_cmap))
    if kept != after_records:
        raise ValueError("profile changed a supported cmap subtable")
    mapping = base_mappings(records)
    if mapping != base_mappings(after_records):
        raise ValueError("profile changed a Unicode base-character mapping")
    mapping_hash = hashlib.sha256(b"".join(struct.pack(">II", point, glyph) for point, glyph in sorted(mapping.items()))).hexdigest()
    manifest = {
        "source": "assets/fonts/NotoSansSCFull.ttf",
        "sourceSha256": SOURCE_SHA256,
        "profile": "NotoSansSCFullPdf.ttf",
        "profileSha256": hashlib.sha256(result).hexdigest(),
        "bytes": len(result),
        "glyphs": struct.unpack_from(">H", source, directory["maxp"][1] + 4)[0],
        "baseUnicodeCharacters": len(mapping),
        "baseUnicodeMappingSha256": mapping_hash,
        "preservedCmapRecords": [{"platform": p, "encoding": e, "format": f, "sha256": hashlib.sha256(body).hexdigest()} for p, e, f, body in kept],
        "removedCmapRecords": [{"platform": p, "encoding": e, "format": f, "bytes": len(body), "variationSelectorRecords": struct.unpack_from(">I", body, 6)[0]} for p, e, f, body in removed],
        "preservedTableSha256": unchanged,
        "license": "SIL Open Font License 1.1; /fonts/OFL.txt; source name/copyright/license tables unchanged",
        "variationSequenceSemantics": "No UVS selection support is added or removed from the existing FontBox PDF renderer, which ignores format 14. Full original source remains unchanged for future UVS support.",
    }
    return result, manifest


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / "assets/fonts/NotoSansSCFull.ttf")
    parser.add_argument("--output", type=Path, default=root / "server/src/main/resources/fonts/NotoSansSCFullPdf.ttf")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--check", action="store_true", help="verify committed bytes without changing files")
    args = parser.parse_args()
    profile, manifest = build_profile(args.source.read_bytes())
    manifest_path = args.manifest or args.output.with_suffix(".json")
    manifest_bytes = (json.dumps(manifest, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    if args.check:
        if args.output.read_bytes() != profile or manifest_path.read_bytes() != manifest_bytes:
            raise SystemExit("PDF font profile or manifest is stale; regenerate and review")
        print("PDF font profile verified: all 30,890 base mappings and 31,036 glyphs preserved")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(profile)
        manifest_path.write_bytes(manifest_bytes)
        print("PDF font profile generated with preserved glyph, metric, layout and base cmap tables")


if __name__ == "__main__":
    main()
