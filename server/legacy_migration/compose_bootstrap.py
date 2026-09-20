#!/usr/bin/env python3
"""Validate a transaction-free loader and emit its original bytes unchanged.

The caller owns BEGIN/COMMIT for standalone and full imports. This lexer is a
fail-closed guard for reviewed SQL, not a rewriter or arbitrary-code sandbox.
Only static CSV imports and the caller-owned key include are psql commands.
PostgreSQL still enforces the outer transaction when the module executes.
"""
from __future__ import annotations

from dataclasses import dataclass
import pathlib
import re
import sys


PRESERVED_TEMP_TABLES = (
    "bootstrap_source_master_ids",
    "bootstrap_legacy_reference_evidence",
    "bootstrap_bom_exclusions",
)
_IDENTIFIER = r"[A-Za-z_][A-Za-z0-9_$]*"
_COPY = re.compile(
    rf"\\copy[ \t]+{_IDENTIFIER}(?:[ \t]*\([ \t]*{_IDENTIFIER}"
    rf"(?:[ \t]*,[ \t]*{_IDENTIFIER})*[ \t]*\))?[ \t]+FROM[ \t]+"
    r"'/tmp/[A-Za-z0-9][A-Za-z0-9_.-]*[.]csv'[ \t]+WITH[ \t]*\("
    r"[ \t]*FORMAT[ \t]+(?:csv|text)[ \t]*,[ \t]*DELIMITER[ \t]+'\|'"
    r"[ \t]*,[ \t]*HEADER[ \t]+true[ \t]*\)[ \t]*",
    re.IGNORECASE,
)
_INCLUDE = re.compile(r"\\i[ \t]+:legacy_key_file[ \t]*")
_DOLLAR = re.compile(r"\$(?:[^\W\d]\w*)?\$")
_TOP_LEVEL_CONTROL = {"BEGIN", "COMMIT", "END", "ROLLBACK", "ABORT", "START", "SAVEPOINT", "RELEASE"}
_PROGRAM_CONTROL = {"COMMIT", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE"}


@dataclass(frozen=True)
class Token:
    kind: str
    value: str
    offset: int


def _line_end(sql: str, start: int) -> int:
    ends = [end for end in (sql.find("\n", start), sql.find("\r", start)) if end >= 0]
    return min(ends, default=len(sql))


def tokens(sql: str):
    """Skip comments, preserving literal boundaries and statement separators."""
    index, length = 0, len(sql)
    while index < length:
        char = sql[index]
        if char.isspace():
            index += 1
            continue
        if sql.startswith("--", index):
            index = _line_end(sql, index + 2)
            continue
        if sql.startswith("/*", index):
            start, depth = index, 1
            index += 2
            while index < length and depth:
                if sql.startswith("/*", index):
                    depth += 1
                    index += 2
                elif sql.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise ValueError(f"unterminated block comment at offset {start}")
            continue
        if char in "'\"":
            start, quote = index, char
            escaped = (quote == "'" and index > 0 and sql[index - 1] in "eE"
                       and (index < 2 or not (sql[index - 2].isalnum() or sql[index - 2] in "_$")))
            index += 1
            closed = False
            while index < length:
                if escaped and sql[index] == "\\":
                    index += 2
                elif sql[index] == quote:
                    if index + 1 < length and sql[index + 1] == quote:
                        index += 2
                    else:
                        index += 1
                        closed = True
                        break
                else:
                    index += 1
            if not closed:
                raise ValueError(f"unterminated quoted value at offset {start}")
            yield Token("STRING" if quote == "'" else "IDENTIFIER", sql[start:index], start)
            continue
        if char == "$" and (delimiter := _DOLLAR.match(sql, index)):
            marker, start = delimiter.group(), index
            end = sql.find(marker, delimiter.end())
            if end < 0:
                raise ValueError(f"unterminated dollar-quoted value at offset {start}")
            yield Token("DOLLAR", sql[delimiter.end():end], start)
            index = end + len(marker)
            continue
        if char == "\\":
            start = index
            index = _line_end(sql, index)
            yield Token("PSQL", sql[start:index], start)
            continue
        if char.isalpha() or char == "_":
            start = index
            index += 1
            while index < length and (sql[index].isalnum() or sql[index] in "_$"):
                index += 1
            yield Token("WORD", sql[start:index].upper(), start)
            continue
        yield Token("SEMICOLON" if char == ";" else "SYMBOL", char, index)
        index += 1


def _transaction_settings(words: list[str]) -> bool:
    return (words[:2] == ["PREPARE", "TRANSACTION"]
            or words[:2] == ["SET", "TRANSACTION"]
            or words[:5] == ["SET", "SESSION", "CHARACTERISTICS", "AS", "TRANSACTION"])


def _validate_program(body: str) -> None:
    body_tokens = list(tokens(body))
    if any(token.kind == "PSQL" for token in body_tokens):
        raise ValueError("psql commands are not allowed inside a procedural body")
    for index, token in enumerate(body_tokens):
        if token.kind != "WORD":
            continue
        previous = body_tokens[index - 1] if index else None
        command_start = previous is None or previous.kind == "SEMICOLON" or (
            previous.kind == "WORD" and previous.value in ("BEGIN", "THEN", "ELSE", "LOOP"))
        if not command_start:
            continue
        word = token.value
        if word in _PROGRAM_CONTROL:
            raise ValueError(f"procedural transaction control is forbidden: {word}")
        if word not in ("START", "PREPARE", "SET", "BEGIN", "END"):
            continue
        words = []
        for position in range(index, len(body_tokens)):
            following = body_tokens[position]
            if following.kind == "SEMICOLON":
                break
            if following.kind == "WORD":
                words.append(following.value)
                if len(words) == 5:
                    break
        if words[:2] == ["START", "TRANSACTION"] or (
                len(words) >= 2 and words[0] in ("BEGIN", "END") and words[1] in ("WORK", "TRANSACTION")):
            raise ValueError(f"procedural transaction control is forbidden: {word}")
        if _transaction_settings(words[:5]):
            raise ValueError("procedural transaction settings are forbidden")
    # Nested dollar strings remain data. Dynamic EXECUTE is constrained by the
    # surrounding PostgreSQL transaction; literal diagnostic text stays intact.


def _validate_statement(statement: list[Token]) -> None:
    if not statement:
        return
    first = statement[0]
    words = [token.value for token in statement if token.kind == "WORD"]
    if first.kind == "WORD" and (first.value in _TOP_LEVEL_CONTROL or _transaction_settings(words)):
        raise ValueError(f"caller-owned transaction control is forbidden: {first.value}")
    create_kind = words[3:4] if words[:3] == ["CREATE", "OR", "REPLACE"] else words[1:2]
    program = first.kind == "WORD" and (first.value == "DO" or (
        first.value == "CREATE" and create_kind in (["FUNCTION"], ["PROCEDURE"])))
    if not program:
        return
    if first.value == "DO":
        bodies = [token for token in statement if token.kind == "DOLLAR"]
        if len(bodies) != 1 or any(token.kind == "STRING" for token in statement):
            raise ValueError("reviewed DO bodies must use one dollar-quoted program")
    else:
        bodies = [statement[index + 1] for index, token in enumerate(statement[:-1])
                  if token.kind == "WORD" and token.value == "AS" and statement[index + 1].kind == "DOLLAR"]
        if len(bodies) != 1:
            raise ValueError("reviewed function/procedure bodies must use one dollar-quoted program")
    for body in bodies:
        _validate_program(body.value)


def validate_sql(sql: str) -> None:
    if "\x00" in sql or sql.startswith("\ufeff"):
        raise ValueError("embedded loaders require UTF-8 without BOM or NUL bytes")
    statement: list[Token] = []
    for token in tokens(sql):
        if token.kind == "PSQL":
            line_start = max(sql.rfind("\n", 0, token.offset), sql.rfind("\r", 0, token.offset)) + 1
            if statement or sql[line_start:token.offset].strip():
                raise ValueError("psql commands must occupy a complete line between SQL statements")
            if not (_COPY.fullmatch(token.value) or _INCLUDE.fullmatch(token.value)):
                raise ValueError("only reviewed static CSV imports and the legacy key include are allowed")
        elif token.kind == "SEMICOLON":
            _validate_statement(statement)
            statement = []
        else:
            statement.append(token)
    if statement:
        _validate_statement(statement)
        raise ValueError("loader must terminate its final SQL statement explicitly")


def compose(content: bytes, name: str) -> bytes:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*[.]sql", name):
        raise ValueError("invalid reviewed loader filename")
    validate_sql(content.decode("utf-8"))
    preserved = ", ".join("'" + table + "'" for table in PRESERVED_TEMP_TABLES)
    cleanup = f"""
DO $$ DECLARE staging_table text; BEGIN
    FOR staging_table IN SELECT relname FROM pg_class
        WHERE relnamespace=pg_my_temp_schema() AND relkind='r'
          AND relname NOT IN ({preserved})
    LOOP EXECUTE format('DROP TABLE pg_temp.%I', staging_table); END LOOP;
END; $$;
"""
    return f"\\echo Bootstrap module: {name}\n".encode() + content + cleanup.encode()


if __name__ == "__main__":
    try:
        source = pathlib.Path(sys.argv[1])
        output = compose(source.read_bytes(), source.name)
        sys.stdout.buffer.write(output)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Bootstrap module rejected: {error}", file=sys.stderr)
        sys.exit(66)
