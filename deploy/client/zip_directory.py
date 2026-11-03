"""Bound Windows producer ZIP metadata before a ZIP library allocates entries.

This is the shared preflight for ordinary, single-disk, non-ZIP64 Windows
payloads. It does not decompress data, validate paths/CRC, or establish trust.
The owning runtime validator retains those checks. Python/Java use the same
contract and vectors in contracts/windows-zip-directory/vectors-v1.json.
"""
from __future__ import annotations

import os
from pathlib import Path
import struct


def _invalid() -> ValueError:
    return ValueError("Windows ZIP directory is malformed, ambiguous, ZIP64 or outside its bounded contract")


def require_bounded_directory(path: Path, *, max_entries: int, max_central_bytes: int) -> dict:
    """Inspect fixed records with bounded memory; call before zipfile.ZipFile.

    Windows producers write contiguous local records from offset zero, then
    the central directory and EOCD. Preambles, gaps, hidden local records and
    ambiguous EOCD signatures inside archive comments are deliberately rejected.
    Conventional 12/16-byte non-ZIP64 data descriptors are supported.
    """
    if (type(max_entries) is not int or not 1 <= max_entries < 65535 or
            type(max_central_bytes) is not int or max_central_bytes < 1):
        raise ValueError("Windows ZIP directory limits must be positive and non-ZIP64")
    with Path(path).open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size

        def read(offset: int, length: int, *, end: int = size) -> bytes:
            if offset < 0 or length < 0 or length > 65557 or offset > end - length:
                raise _invalid()
            stream.seek(offset)
            data = stream.read(length)
            if len(data) != length:
                raise _invalid()
            return data

        tail = read(max(0, size - 65557), min(size, 65557))
        position = tail.rfind(b"PK\x05\x06")
        if position < 0 or position + 22 > len(tail):
            raise _invalid()
        disk, start_disk, disk_count, count, length, offset, comment = struct.unpack_from("<HHHHIIH", tail, position + 4)
        eocd = size - len(tail) + position
        if (disk or start_disk or disk_count != count or count == 65535 or count > max_entries
                or length == 0xffffffff or offset == 0xffffffff or length > max_central_bytes
                or length < count * 46 or offset > eocd or length != eocd - offset
                or position + 22 + comment != len(tail)):
            raise _invalid()
        archive_comment = tail[position + 22:]
        if b"PK\x06\x06" in archive_comment or b"PK\x06\x07" in archive_comment:
            raise _invalid()

        def extra_fields(extra: bytes) -> None:
            index = 0
            while index < len(extra):
                if index + 4 > len(extra):
                    raise _invalid()
                tag, amount = struct.unpack_from("<HH", extra, index)
                index += 4
                if tag == 1 or amount > len(extra) - index:
                    raise _invalid()
                index += amount

        ranges = []
        cursor = offset
        for _ in range(count):
            header = read(cursor, 46, end=eocd)
            if header[:4] != b"PK\x01\x02":
                raise _invalid()
            flags, method = struct.unpack_from("<HH", header, 8)
            crc, compressed, expanded = struct.unpack_from("<III", header, 16)
            name_length, extra_length, comment_length, entry_disk = struct.unpack_from("<HHHH", header, 28)
            local = struct.unpack_from("<I", header, 42)[0]
            record_length = 46 + name_length + extra_length + comment_length
            if (entry_disk or compressed == 0xffffffff or expanded == 0xffffffff or local == 0xffffffff
                    or not name_length or record_length > eocd - cursor):
                raise _invalid()
            name = read(cursor + 46, name_length, end=eocd)
            extra_fields(read(cursor + 46 + name_length, extra_length, end=eocd))
            local_header = read(local, 30, end=offset)
            if local_header[:4] != b"PK\x03\x04":
                raise _invalid()
            local_flags, local_method = struct.unpack_from("<HH", local_header, 6)
            local_crc, local_compressed, local_expanded = struct.unpack_from("<III", local_header, 14)
            local_name_length, local_extra_length = struct.unpack_from("<HH", local_header, 26)
            if (local_flags != flags or local_method != method or local_name_length != name_length
                    or local_compressed == 0xffffffff or local_expanded == 0xffffffff
                    or read(local + 30, local_name_length, end=offset) != name):
                raise _invalid()
            extra_fields(read(local + 30 + local_name_length, local_extra_length, end=offset))
            data_end = local + 30 + local_name_length + local_extra_length + compressed
            if data_end > offset:
                raise _invalid()
            if flags & 8:
                first = read(data_end, 4, end=offset)
                descriptor_size = 16 if first == b"PK\x07\x08" else 12
                descriptor = read(data_end, descriptor_size, end=offset)
                values = struct.unpack_from("<III", descriptor, 4 if descriptor_size == 16 else 0)
                if values != (crc, compressed, expanded):
                    raise _invalid()
                data_end += descriptor_size
            elif (local_crc, local_compressed, local_expanded) != (crc, compressed, expanded):
                raise _invalid()
            ranges.append((local, data_end))
            cursor += record_length
        if cursor != eocd:
            raise _invalid()
        previous = 0
        for start, end in sorted(ranges):
            if start != previous or end < start:
                raise _invalid()
            previous = end
        if previous != offset:
            raise _invalid()
        return {"entries": count, "centralBytes": length, "centralOffset": offset}
