#!/usr/bin/env python3
"""Write private psql key variables without shell evaluation or meta-command escapes.

Environment values take precedence, as in the application. File values follow
the project's dotenv-java 3.0 parser: trim ASCII whitespace, strip paired double
quotes, retain literal backslashes and single quotes. Ambiguous duplicate keys
are rejected. Secret values never appear in diagnostics or on stdout.
"""
from __future__ import annotations

import os
import pathlib
import re
import sys


KEYS = ("UTEN_PGP_MASTER_KEY", "UTEN_PGP_KEY_VERSION", "UTEN_HMAC_KEY")
ASCII_SPACE = "".join(chr(value) for value in range(33))
ENTRY = re.compile(r"\s*([\w.\-]+)\s*(=)\s*('[^']*'|\"[^\"]*\"|[^#]*)?\s*(#.*)?", re.ASCII)


class CryptoConfigurationError(ValueError):
    """Contains only a fixed diagnostic or a public configuration key name."""


def read_crypto(source: pathlib.Path, environment: dict[str, str]) -> dict[str, str]:
    values: dict[str, str] = {}
    if source.exists():
        content = source.read_text(encoding="utf-8")
        if content.startswith("\ufeff") or "\x00" in content:
            raise CryptoConfigurationError("Crypto environment source must be UTF-8 without BOM or NUL")
        for original in content.splitlines():
            line = original.strip(ASCII_SPACE)
            if not line or line.startswith(("#", "////")):
                continue
            match = ENTRY.fullmatch(line)
            if not match:
                if any(key in line for key in KEYS):
                    raise CryptoConfigurationError("Malformed crypto environment assignment")
                continue
            key, value = match.group(1), (match.group(3) or "").strip(ASCII_SPACE)
            if key not in KEYS:
                continue
            if key in values:
                raise CryptoConfigurationError("Duplicate crypto environment assignment: " + key)
            if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            values[key] = value
    for key in KEYS:
        if key in environment:
            values[key] = environment[key]
    for key in ("UTEN_PGP_MASTER_KEY", "UTEN_HMAC_KEY"):
        if not values.get(key) or not values[key].strip():
            raise CryptoConfigurationError("Missing crypto configuration: " + key)
    # Matches CryptoProperties/application.yml. Never relabel an explicit version.
    values.setdefault("UTEN_PGP_KEY_VERSION", "1")
    version = values["UTEN_PGP_KEY_VERSION"]
    if not version or any(character in version for character in (":", "\r", "\n", "\x00")):
        raise CryptoConfigurationError("Invalid crypto key version")
    if any("\x00" in value for value in values.values()):
        raise CryptoConfigurationError("Crypto configuration cannot contain NUL")
    return values


def sql_literal(value: str) -> str:
    """An explicit PostgreSQL escape literal preserves both real and literal LF."""
    return "E'" + value.replace("\\", "\\\\").replace("'", "''").replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t") + "'"


def render(values: dict[str, str]) -> bytes:
    # \gset consumes the single result without displaying its secret values.
    # Do not add a semicolon before it: that would execute/display SELECT first.
    return ("SELECT " + sql_literal(values["UTEN_PGP_MASTER_KEY"]) + " AS pgp_key, "
            + sql_literal(values["UTEN_PGP_KEY_VERSION"]) + " AS pgp_ver, "
            + sql_literal(values["UTEN_HMAC_KEY"]) + " AS hmac_key\n\\gset\n").encode("utf-8")


def write_private(destination: pathlib.Path, content: bytes) -> None:
    flags = os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(destination, flags)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, 0o600)
        else:
            # Git Bash already created/chmod'ed this private file; retain its
            # Windows read/write mode without requiring an unavailable fchmod.
            os.chmod(destination, 0o600)
        with os.fdopen(descriptor, "wb", closefd=False) as output:
            output.write(content)
    finally:
        os.close(descriptor)


def main(arguments: list[str]) -> None:
    if len(arguments) != 2:
        raise CryptoConfigurationError("Expected environment source and private output path")
    write_private(pathlib.Path(arguments[1]), render(read_crypto(pathlib.Path(arguments[0]), dict(os.environ))))


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except CryptoConfigurationError as error:
        print("Crypto initialization rejected: " + str(error), file=sys.stderr)
        sys.exit(66)
    except (OSError, UnicodeError, ValueError):
        print("Crypto initialization rejected: private input/output is unavailable or invalid", file=sys.stderr)
        sys.exit(66)
