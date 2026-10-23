#!/usr/bin/env python3
"""Read-only, fail-closed CSV/header contracts for reviewed static psql loaders.

This is deliberately not a PostgreSQL interpreter. Only top-level temporary
table shapes and static \\copy commands are interpreted; procedural bodies are
opaque. Each module starts a new scope, matching compose_bootstrap's cleanup.
Unknown shapes are retained as unknown and rejected if subsequently copied.
No SQL is run and no input is changed. Values/data rows are never reported.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import re
import sys
from typing import Iterable

from compose_bootstrap import Token, tokens


class CSVContractError(ValueError):
    """A preflight rejection with a JSON-serializable, data-free report."""

    def __init__(self, report: dict):
        self.report = report
        super().__init__("Loader CSV contract rejected: " + "; ".join(
            f"{issue['module']}:{issue['line']}: {issue['message']}"
            for issue in report['issues']))


def _word(token: Token, value: str) -> bool:
    return token.kind == 'WORD' and token.value == value


def _identifier(items: list[Token], index: int) -> tuple[str, int]:
    if index >= len(items):
        raise ValueError('expected a static identifier')
    token = items[index]
    if token.kind == 'WORD':
        return token.value.lower(), index + 1
    if token.kind == 'IDENTIFIER':
        return token.value[1:-1].replace('""', '"'), index + 1
    raise ValueError('expected a static identifier')


def _table_name(items: list[Token], index: int) -> tuple[str, int]:
    name, index = _identifier(items, index)
    if index < len(items) and items[index].value == '.':
        if name != 'pg_temp':
            raise ValueError('COPY/temporary table schema must be pg_temp')
        name, index = _identifier(items, index + 1)
    return name, index


def _groups(items: list[Token]) -> list[list[Token]]:
    """Split only outer commas, including nested type/default expressions."""
    result, current, stack = [], [], []
    for token in items:
        if token.kind == 'SYMBOL' and token.value in ('(', '['):
            stack.append(token.value)
        elif token.kind == 'SYMBOL' and token.value in (')', ']'):
            if not stack or stack.pop() != {')': '(', ']': '['}[token.value]:
                raise ValueError('unbalanced SQL definition')
        if token.kind == 'SYMBOL' and token.value == ',' and not stack:
            if not current:
                raise ValueError('empty SQL definition entry')
            result.append(current)
            current = []
        else:
            current.append(token)
    if stack:
        raise ValueError('unbalanced SQL definition')
    if current:
        result.append(current)
    elif result:
        raise ValueError('empty SQL definition entry')
    return result


def _parenthesized(items: list[Token], index: int) -> tuple[list[Token], int]:
    if index >= len(items) or items[index].value != '(':
        raise ValueError('expected a parenthesized static definition')
    depth = 0
    for end in range(index, len(items)):
        token = items[end]
        if token.kind == 'SYMBOL' and token.value == '(':
            depth += 1
        elif token.kind == 'SYMBOL' and token.value == ')':
            depth -= 1
            if depth == 0:
                return items[index + 1:end], end + 1
    raise ValueError('unbalanced SQL definition')


_CONSTRAINTS = {'CONSTRAINT', 'PRIMARY', 'UNIQUE', 'CHECK', 'FOREIGN', 'EXCLUDE'}


def _create(items: list[Token], stages: dict[str, tuple[str, ...] | None]) -> None:
    index = 1
    if index < len(items) and items[index].value in ('LOCAL', 'GLOBAL'):
        index += 1
    if index >= len(items) or items[index].kind != 'WORD' or items[index].value not in ('TEMP', 'TEMPORARY'):
        return
    index += 1
    if index >= len(items) or not _word(items[index], 'TABLE'):
        return
    index += 1
    if_not_exists = [token.value for token in items[index:index + 3]] == ['IF', 'NOT', 'EXISTS']
    if if_not_exists:
        index += 3
    name, index = _table_name(items, index)
    if if_not_exists and name in stages:
        return
    # CTAS, inherited, or otherwise opaque shapes cannot authorize a later COPY.
    stages[name] = None
    if index >= len(items) or items[index].value != '(':
        return
    definition, end = _parenthesized(items, index)
    if any(_word(token, 'AS') or _word(token, 'INHERITS') for token in items[end:]):
        return
    columns: list[str] = []
    for entry in _groups(definition):
        if entry[0].kind == 'WORD' and entry[0].value in _CONSTRAINTS:
            continue
        if _word(entry[0], 'LIKE'):
            source, _ = _table_name(entry, 1)
            source_columns = stages.get(source)
            if source_columns is None:
                return
            columns.extend(source_columns)
            continue
        column, next_index = _identifier(entry, 0)
        if next_index >= len(entry):
            return  # CTAS column-name lists do not prove the query's arity.
        if any(_word(token, 'GENERATED') for token in entry[next_index:]):
            return  # Implicit COPY omits generated columns; do not guess.
        columns.append(column)
    if not columns or len(set(columns)) != len(columns):
        raise ValueError('temporary table has no columns or duplicate column identifiers')
    stages[name] = tuple(columns)


def _alter(items: list[Token], stages: dict[str, tuple[str, ...] | None]) -> None:
    if len(items) < 3 or not _word(items[1], 'TABLE'):
        return
    index = 2
    if [token.value for token in items[index:index + 2]] == ['IF', 'EXISTS']:
        index += 2
    if index < len(items) and _word(items[index], 'ONLY'):
        index += 1
    name, index = _table_name(items, index)
    if name not in stages or stages[name] is None:
        return
    columns = list(stages[name])
    for action in _groups(items[index:]):
        verb, offset = action[0].value, 1
        if verb not in ('ADD', 'DROP', 'RENAME') or action[0].kind != 'WORD':
            stages[name] = None
            return
        if offset < len(action) and _word(action[offset], 'COLUMN'):
            offset += 1
        if offset < len(action) and action[offset].kind == 'WORD' and action[offset].value in _CONSTRAINTS:
            continue  # A table constraint cannot change the COPY arity.
        conditional = [token.value for token in action[offset:offset + 3]] == ['IF', 'NOT', 'EXISTS']
        if conditional:
            offset += 3
        elif [token.value for token in action[offset:offset + 2]] == ['IF', 'EXISTS']:
            conditional = True
            offset += 2
        column, offset = _identifier(action, offset)
        if verb == 'ADD':
            if offset >= len(action) or any(_word(token, 'GENERATED') for token in action[offset:]):
                stages[name] = None
                return
            if column in columns:
                if not conditional:
                    raise ValueError('duplicate ALTER column')
            else:
                columns.append(column)
        elif verb == 'DROP':
            if column in columns:
                columns.remove(column)
            elif not conditional:
                raise ValueError('unknown ALTER column')
        else:
            if column not in columns or offset >= len(action) or not _word(action[offset], 'TO'):
                raise ValueError('unresolved column rename')
            replacement, offset = _identifier(action, offset + 1)
            if offset != len(action) or replacement in columns:
                raise ValueError('invalid column rename')
            columns[columns.index(column)] = replacement
    stages[name] = tuple(columns)


def _drop(items: list[Token], stages: dict[str, tuple[str, ...] | None]) -> None:
    if len(items) < 3 or not _word(items[1], 'TABLE'):
        return
    index = 2
    if [token.value for token in items[index:index + 2]] == ['IF', 'EXISTS']:
        index += 2
    for entry in _groups(items[index:]):
        name, _ = _table_name(entry, 0)
        stages.pop(name, None)


def _copy(command: str, stages: dict[str, tuple[str, ...] | None], input_dir: Path) -> dict:
    items = list(tokens(command[1:]))
    if not items or not _word(items[0], 'COPY'):
        raise ValueError('not a static COPY command')
    stage, index = _table_name(items, 1)
    columns = stages.get(stage)
    if columns is None:
        raise ValueError(f'COPY stage {stage!r} has no resolvable top-level temporary table definition')
    copy_columns: list[str] | None = None
    if index < len(items) and items[index].value == '(':
        group, index = _parenthesized(items, index)
        copy_columns = []
        for part in _groups(group):
            column, end = _identifier(part, 0)
            if end != len(part) or column not in columns:
                raise ValueError('explicit COPY column is unresolved')
            copy_columns.append(column)
        if not copy_columns or len(set(copy_columns)) != len(copy_columns):
            raise ValueError('explicit COPY columns must be nonempty and unique')
    if index + 2 >= len(items) or not _word(items[index], 'FROM') or items[index + 1].kind != 'STRING':
        raise ValueError('COPY requires a static CSV file, not PROGRAM/query/variables')
    raw_path = items[index + 1].value
    if not re.fullmatch(r"'/tmp/[A-Za-z0-9][A-Za-z0-9_.-]*[.]csv'", raw_path):
        raise ValueError('COPY input must be a static /tmp/<basename>.csv')
    filename = raw_path[len("'/tmp/"):-1]
    index += 2
    if index >= len(items) or not _word(items[index], 'WITH'):
        raise ValueError('COPY must declare FORMAT, DELIMITER, and HEADER')
    options, index = _parenthesized(items, index + 1)
    if index < len(items) and items[index].kind == 'SEMICOLON':
        index += 1
    if index != len(items):
        raise ValueError('unparsed COPY command suffix')
    option_values = {}
    for entry in _groups(options):
        if len(entry) == 3 and entry[1].value == '=':
            entry = [entry[0], entry[2]]
        if len(entry) != 2 or entry[0].kind != 'WORD' or entry[0].value in option_values:
            raise ValueError('COPY options cannot be resolved statically')
        option_values[entry[0].value] = entry[1].value
    if option_values not in ({'FORMAT': 'CSV', 'DELIMITER': "'|'", 'HEADER': 'TRUE'},
                             {'FORMAT': 'TEXT', 'DELIMITER': "'|'", 'HEADER': 'TRUE'}):
        raise ValueError('COPY contract requires reviewed pipe-delimited HEADER true options')
    path = input_dir / filename
    if not path.is_file():
        raise ValueError(f'required COPY CSV is missing: {filename}')
    try:
        with path.open('r', encoding='utf-8-sig', newline='') as source:
            header = next(csv.reader(source, delimiter='|', strict=True), None)
    except (OSError, UnicodeError, csv.Error) as error:
        raise ValueError(f'COPY CSV header cannot be read: {filename} ({type(error).__name__})') from error
    if not header or any(not value.strip() for value in header):
        raise ValueError(f'COPY CSV has an empty or missing header: {filename}')
    expected = len(copy_columns if copy_columns is not None else columns)
    if len(header) != expected:
        raise ValueError(f'COPY CSV {filename} has {len(header)} header columns; stage {stage!r} expects {expected}')
    return {'stage': stage, 'csv': filename, 'header_columns': len(header),
            'expected_columns': expected, 'explicit_copy_columns': copy_columns is not None}


def _inspect_module(name: str, content: str | bytes, input_dir: Path) -> tuple[list[dict], list[dict]]:
    contracts, issues, stages = [], [], {}
    sql = content.decode('utf-8') if isinstance(content, bytes) else content
    statement: list[Token] = []
    in_statement = False
    capture = False

    def reject(offset: int, error: Exception) -> None:
        issues.append({'module': name, 'line': sql.count('\n', 0, offset) + 1, 'message': str(error)})

    for token in tokens(sql):
        if token.kind == 'PSQL':
            if not re.match(r'\\copy\b', token.value, re.IGNORECASE):
                continue
            try:
                line_start = max(sql.rfind('\n', 0, token.offset), sql.rfind('\r', 0, token.offset)) + 1
                if in_statement or sql[line_start:token.offset].strip():
                    raise ValueError('COPY must occupy a complete line between SQL statements')
                record = _copy(token.value, stages, input_dir)
                record.update(module=name, line=sql.count('\n', 0, token.offset) + 1)
                contracts.append(record)
            except ValueError as error:
                reject(token.offset, error)
        elif token.kind == 'SEMICOLON':
            if statement:
                try:
                    {'CREATE': _create, 'ALTER': _alter, 'DROP': _drop}[statement[0].value](statement, stages)
                except ValueError as error:
                    reject(statement[0].offset, error)
                    # A malformed DDL must not retain a formerly known shape.
                    stages.clear()
            statement, in_statement, capture = [], False, False
        else:
            if not in_statement:
                in_statement = True
                capture = token.kind == 'WORD' and token.value in ('CREATE', 'ALTER', 'DROP')
            if capture:
                statement.append(token)
    if in_statement:
        reject(statement[0].offset if statement else len(sql),
               ValueError('loader has an unterminated final SQL statement'))
    return contracts, issues


def validate_modules(modules: Iterable[tuple[str, str | bytes]], input_directory: str | Path) -> dict:
    """Return safe contract metadata, or reject all issues before any SQL executes.

    Pass the actual concatenated SQL content that will execute (including any
    module sidecar), before compose_bootstrap adds its automatic temp cleanup.
    """
    input_dir = Path(input_directory)
    contracts, issues, count = [], [], 0
    for name, content in modules:
        count += 1
        try:
            accepted, rejected = _inspect_module(str(name), content, input_dir)
            contracts.extend(accepted)
            issues.extend(rejected)
        except (OSError, UnicodeError, ValueError) as error:
            issues.append({'module': str(name), 'line': 1, 'message': str(error)})
    report = {'format': 'loader-csv-contract-v1', 'valid': not issues,
              'module_count': count, 'copy_count': len(contracts), 'contracts': contracts, 'issues': issues}
    if issues:
        raise CSVContractError(report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-dir', required=True, type=Path)
    parser.add_argument('--module', action='append', required=True, type=Path)
    arguments = parser.parse_args()
    try:
        report = validate_modules(((path.name, path.read_bytes()) for path in arguments.module), arguments.input_dir)
    except CSVContractError as error:
        print(json.dumps(error.report, ensure_ascii=False, indent=2))
        return 66
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
