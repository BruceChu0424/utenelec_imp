#!/usr/bin/env python3
"""Check/embed the canonical finite restore helper in the unpublished V977.

After publication these bytes are immutable; a changed helper requires a new
version and forward migration. The standalone SQL also finalizes later restores.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
START = '-- BEGIN CANONICAL EMPLOYEE SEALED OWNER-DEFAULT ACL RESTORE\n'
END = '-- END CANONICAL EMPLOYEE SEALED OWNER-DEFAULT ACL RESTORE\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    helper = (ROOT / 'server/maintenance/restore_employee_sealed_owner_default_acls.sql').read_text(encoding='utf-8')
    migration = ROOT / 'server/src/main/resources/db/migration/V977__employee_six_digit_numbers.sql'
    body = migration.read_text(encoding='utf-8')
    expected = START + helper.rstrip() + '\n' + END + '\n'
    if START in body or END in body:
        if not body.startswith(START) or body.count(START) != 1 or body.count(END) != 1:
            raise SystemExit('Unexpected canonical restore block boundaries')
        remainder = body.split(END, 1)[1].lstrip('\n')
    else:
        remainder = body
    rendered = expected + remainder
    if args.write:
        migration.write_text(rendered, encoding='utf-8', newline='\n')
    elif body != rendered:
        raise SystemExit('V977 restore block differs from its canonical maintenance helper')
    print('Employee sealed-owner ACL restore: canonical helper and V977 agree')


if __name__ == '__main__':
    main()
