"""Render one reviewed, account-free resigned duplicate correction; never connects to a database."""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import uuid

PROTOCOL = "verified-employee-resigned-duplicate-v1"

def validate_plan(plan: dict) -> None:
    def require(ok, message):
        if not ok: raise ValueError(message)
    def exact(node, fields): require(isinstance(node, dict) and set(node) == set(fields), "Unreviewed or missing plan fields")
    def text(value, maximum=1000): require(isinstance(value,str) and 1<=len(value.strip())<=maximum and all(ord(c)>=32 for c in value),"Missing or unsafe evidence text")
    def sha(value): require(isinstance(value,str) and re.fullmatch(r"[0-9a-f]{64}",value) is not None,"Missing SHA256 evidence")
    def identity(value): require(isinstance(value,str) and str(uuid.UUID(value))==value,"Use canonical UUID identities")
    def integer(value): require(type(value) is int and value>=0,"Expected nonnegative version")
    exact(plan,{"protocol","captured_at","database_identity","canonical","duplicate","evidence","backup","maintenance_actor"})
    require(plan["protocol"]==PROTOCOL,"Wrong maintenance protocol")
    captured=dt.datetime.fromisoformat(plan["captured_at"])
    require(captured.tzinfo is not None,"Evidence needs an explicit timezone")
    require(-dt.timedelta(minutes=5)<=dt.datetime.now(dt.timezone.utc)-captured<=dt.timedelta(hours=24),"Expired or future evidence")
    database=plan["database_identity"]
    exact(database,{"database","system_identifier","database_oid","dataset_id","generation","migration_max","migration_sha256"})
    text(database["database"],63);identity(database["dataset_id"]);sha(database["migration_sha256"])
    require(isinstance(database["system_identifier"],str) and re.fullmatch(r"[0-9]{1,20}",database["system_identifier"]) is not None,"Missing physical cluster pin")
    for key in ("database_oid","generation","migration_max"): integer(database[key])
    require(database["migration_max"]>=947,"V937/V947 must already be deployed; this tool never deploys migrations")
    for key in ("canonical","duplicate"):
        node=plan[key];exact(node,{"employee_id","code","version"}|({"reason"} if key=="duplicate" else set()))
        identity(node["employee_id"]);text(node["code"],128);integer(node["version"])
    require(plan["canonical"]["employee_id"]!=plan["duplicate"]["employee_id"],"Cannot archive the retained identity")
    text(plan["duplicate"]["reason"]);require(len(plan["duplicate"]["reason"].strip())>=5,"Explicit correction reason required")
    evidence=plan["evidence"]
    exact(evidence,{"reference","sha256","canonical_sensitive_sha256","duplicate_sensitive_sha256","document_equal","birth_equal","valid_resident_id"})
    text(evidence["reference"])
    for key in ("sha256","canonical_sensitive_sha256","duplicate_sensitive_sha256"): sha(evidence[key])
    for key in ("document_equal","birth_equal","valid_resident_id"): require(evidence[key] is True,"Same-name/partial identifier evidence is insufficient")
    backup=plan["backup"];exact(backup,{"reference","manifest_sha256","verified"})
    text(backup["reference"]);sha(backup["manifest_sha256"]);require(backup["verified"] is True,"Require a verified paired backup receipt")
    text(plan["maintenance_actor"],128)

def render(plan: dict, *, commit: bool=False) -> str:
    validate_plan(plan)
    body=Path(__file__).with_name("verified_employee_resigned_duplicate.sql").read_text(encoding="utf-8")
    literal=json.dumps(plan,ensure_ascii=False,separators=(",",":")).replace("'","''")
    return ("\\set ON_ERROR_STOP on\nBEGIN ISOLATION LEVEL REPEATABLE READ;\nSET LOCAL standard_conforming_strings=on;\n"
            +body+"\nSELECT pg_temp.apply_verified_resigned_employee_duplicate('"+literal+"'::jsonb);\n"
            +("COMMIT;\n" if commit else "ROLLBACK;\n"))

def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan",type=Path,required=True);parser.add_argument("--out",type=Path,required=True)
    parser.add_argument("--evidence-file",type=Path,required=True)
    parser.add_argument("--commit",action="store_true",help="Render COMMIT; default always renders ROLLBACK")
    args=parser.parse_args();plan=json.loads(args.plan.read_text(encoding="utf-8-sig"))
    validate_plan(plan)
    if hashlib.sha256(args.evidence_file.read_bytes()).hexdigest()!=plan["evidence"]["sha256"]:
        raise ValueError("Normalized identity evidence file SHA256 differs from the reviewed plan")
    with args.out.open("x",encoding="utf-8",newline="\n") as output: output.write(render(plan,commit=args.commit))
    print(json.dumps({"state":"RENDERED_ONLY","transaction":"COMMIT" if args.commit else "ROLLBACK","output":str(args.out),"database_connections":0}))
    return 0

if __name__=="__main__": raise SystemExit(main())
