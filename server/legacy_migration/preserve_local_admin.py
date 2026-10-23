#!/usr/bin/env python3
"""Preserve the existing local administrator hash without knowing the password.

The private snapshot is never printed. Restore can write only a fresh rehearsal
database; it maps the account to that schema's ADMIN employee and verifies the
entire account row plus the password hash after insertion.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from rehearse_local_import import Database, literal


def source_account() -> dict:
    result = subprocess.run(['docker','exec','uten-imp-postgres','psql','-X','-A','-t','-q',
                             '-U','uten','-d','uten_imp','-v','ON_ERROR_STOP=1','-c',
        "SELECT to_jsonb(u) FROM users u JOIN employees e ON e.id=u.employee_id "
        "WHERE u.login_account='17665410007' AND u.is_super_admin AND u.status='active' "
        "AND NOT u.is_deleted AND e.code='ADMIN' AND NOT e.is_deleted"],
        check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    rows = result.stdout.decode('utf-8').strip().splitlines()
    if len(rows) != 1:
        raise ValueError('Exactly one enabled protected local administrator must exist')
    return json.loads(rows[0])


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=('capture','restore','verify-source'))
    parser.add_argument('--snapshot',type=Path,required=True)
    parser.add_argument('--database')
    args=parser.parse_args()
    db=Database('uten-imp-postgres',args.database or 'unused_rehearsal','uten')
    db.verify_local()
    if args.command=='capture':
        if args.snapshot.exists():
            raise ValueError('Refusing to overwrite the protected original account snapshot')
        args.snapshot.write_text(json.dumps(source_account()),encoding='utf-8')
        args.snapshot.chmod(0o600)
        print('ADMIN_CAPTURED account=17665410007 password_not_printed=true')
        return
    original=json.loads(args.snapshot.read_text(encoding='utf-8'))
    if args.command=='verify-source':
        if source_account()['password_hash'] != original['password_hash']:
            raise ValueError('Original administrator password changed since capture')
        print('ADMIN_SOURCE_PASSWORD_UNCHANGED')
        return
    if not args.database:
        raise ValueError('An explicit fresh rehearsal database is required')
    if db.sql('SELECT count(*) FROM users;')!='0':
        raise ValueError('Administrator restore requires zero existing accounts')
    sql=("BEGIN;\nSET LOCAL app.legacy_import='on';\n"
         "INSERT INTO users SELECT (jsonb_populate_record(NULL::users,"+literal(json.dumps(original))+
         "::jsonb || jsonb_build_object('employee_id',(SELECT id FROM employees WHERE code='ADMIN')))).*;\n"
         "DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM users u WHERE login_account='17665410007' AND "
         "to_jsonb(u)-ARRAY['employee_id','updated_at'] = "+literal(json.dumps(original))+
         "::jsonb-ARRAY['employee_id','updated_at']) THEN "
         "RAISE EXCEPTION 'Protected administrator differs after restore'; END IF; END $$;\nCOMMIT;\n")
    db.sql(sql)
    actual=json.loads(db.sql("SELECT to_jsonb(u) FROM users u WHERE login_account='17665410007';"))
    for key,value in original.items():
        if key not in ('employee_id','updated_at') and actual.get(key)!=value:
            raise ValueError('Restored administrator differs in field '+key)
    print('ADMIN_RESTORED account=17665410007 original_password_hash_preserved=true')


if __name__=='__main__':
    main()
