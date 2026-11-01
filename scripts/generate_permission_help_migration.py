#!/usr/bin/env python3
"""Render a metadata-only migration from the reviewed permission-help.json.

Use --write only for a new, unpublished migration. Applied migration bytes must
stay immutable; a subsequent catalog revision needs a new --migration path.
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def render():
    catalog = json.loads((ROOT / 'server/src/main/resources/permission-help.json').read_text(encoding='utf-8'))
    if catalog['schemaVersion'] != 1:
        raise ValueError('Unsupported permission help schema')
    rows = catalog['permissions']
    if len({row['code'] for row in rows}) != len(rows):
        raise ValueError('Duplicate permission code')
    def quote(value):
        return "'" + value.replace("'", "''") + "'"
    values = []
    for row in sorted(rows, key=lambda value: value['code']):
        if not row['name'] or '例如：' not in row['description']:
            raise ValueError('Every permission needs a readable name and example')
        values.append(' (' + ','.join(quote(row[key]) for key in ('code', 'name', 'description')) + ')')
    return ('-- Generated from permission-help.json. Names and explanations only; no authority or grant changes.\n'
            'UPDATE permissions p SET name=help.name,description=help.description\n'
            'FROM (VALUES\n' + ',\n'.join(values)
            + '\n) AS help(code,name,description) WHERE p.code=help.code;\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--migration', required=True)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    destination = (ROOT / args.migration).resolve()
    boundary = ROOT / 'server/src/main/resources/db/migration'
    if not destination.is_relative_to(boundary.resolve()) or destination.suffix != '.sql':
        raise ValueError('Output must be a repository migration SQL file')
    expected = render()
    if args.write:
        destination.write_text(expected, encoding='utf-8', newline='\n')
    elif not destination.is_file() or destination.read_text(encoding='utf-8') != expected:
        raise SystemExit('Permission help migration differs from its reviewed catalog')
    print('Permission help metadata: source and migration agree')


if __name__ == '__main__':
    main()
