"""Pinned, explicit user-scope reduction of the production loader; no execution."""
import hashlib,json,pathlib,re,sys
ROOT=pathlib.Path(__file__).resolve().parent
SOURCE=pathlib.Path(__file__).with_name("migrate_production.sql")
SOURCE_SHA="5dee0d0b7ef835625628e0daa229ec34a53e34e79d4c4c088e7be4ad54004588"
def sha(b):return hashlib.sha256(b).hexdigest()
def once(s,old,new):
    if s.count(old)!=1:raise ValueError("pinned production source boundary changed")
    return s.replace(old,new,1)
def marker(s,n):
    found=re.findall(r"^-- =+ "+str(n)+r"\. .*?=+\s*$",s,re.M)
    if len(found)!=1:raise ValueError("ambiguous section "+str(n))
    return found[0]
def split_production(content:bytes)->bytes:
    if sha(content)!=SOURCE_SHA:raise ValueError("unreviewed production source SHA")
    source=content.decode("utf-8").replace("\r\n","\n")
    start=source.index(marker(source,0))
    cost=source.index(marker(source,5))
    original_plan_block=source[source.index(marker(source,3)):cost]
    body=source[start:cost]
    body=once(body,"DELETE FROM production_plan_costs;\n","")
    copy="\\copy cost_stage FROM '/tmp/production_plan_costs.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)\n"
    body=once(body,copy,"-- cost_stage deliberately remains EMPTY; production costs are SKIPPED_USER.\n")
    body=once(body,
        "          SELECT mgoods_legacy_id FROM item_stage WHERE mgoods_legacy_id IS NOT NULL AND mgoods_legacy_id <> 0 UNION ALL\n"
        "          SELECT goods_legacy_id FROM cost_stage WHERE goods_legacy_id IS NOT NULL AND goods_legacy_id <> 0 UNION ALL\n"
        "          SELECT mgoods_legacy_id FROM cost_stage WHERE mgoods_legacy_id IS NOT NULL AND mgoods_legacy_id <> 0) t",
        "          SELECT mgoods_legacy_id FROM item_stage WHERE mgoods_legacy_id IS NOT NULL AND mgoods_legacy_id <> 0) t")
    body=once(body,
        "FROM (SELECT color_legacy_id AS lid FROM item_stage WHERE color_legacy_id IS NOT NULL AND color_legacy_id <> 0 UNION ALL\n"
        "      SELECT color_legacy_id FROM cost_stage WHERE color_legacy_id IS NOT NULL AND color_legacy_id <> 0 UNION ALL\n"
        "      SELECT mcolor_legacy_id FROM cost_stage WHERE mcolor_legacy_id IS NOT NULL AND mcolor_legacy_id <> 0) t",
        "FROM (SELECT color_legacy_id AS lid FROM item_stage WHERE color_legacy_id IS NOT NULL AND color_legacy_id <> 0) t")
    supplier_start=body.index("-- 供应商（从 BOM 建议供应反推）")
    plan_start=body.index(marker(body,3))
    body=body[:supplier_start]+"-- No supplier stubs are derived from skipped cost rows.\n\n"+body[plan_start:]
    # No edits are permitted to the actual plan/header/item source registration
    # and mapping. The source proof still contains the exact real original rows.
    if body[body.index(marker(body,3)):]!=original_plan_block:
        raise ValueError("plan/provenance block changed")
    executable="\n".join(x for x in body.splitlines() if not x.lstrip().startswith("--"))
    forbidden=[r"\\copy\s+cost_stage",r"\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|TRUNCATE)\s+(?:public\.)?production_plan_costs\b",
        r"\b(?:FROM|JOIN)\s+cost_stage\b",r"\bcost_prepared\b",r"\bINSERT\s+INTO\s+suppliers\b"]
    if any(re.search(p,executable,re.I) for p in forbidden):raise ValueError("cost scope leaked")
    if len(re.findall(r"CREATE TEMP TABLE cost_stage\b",executable,re.I))!=1:raise ValueError("empty stage contract changed")
    header=("-- EXPLICIT USER REDUCED SCOPE: production plans/items only; production costs SKIPPED_USER.\n"
        "-- Derived from frozen source raw SHA256 "+SOURCE_SHA+".\n"
        "-- Empty cost_stage is schema compatibility only; no cost CSV, row writes or cost-derived stubs.\n"
        "-- Original V913 source registration and plan/item mappings remain byte-equivalent after LF normalization.\n")
    return (header+body+
        "\nANALYZE public.production_plans;\nANALYZE public.production_plan_items;\n"
        "REFRESH MATERIALIZED VIEW production_monthly_mv;\n").encode()
def main():
    result=split_production(SOURCE.read_bytes())
    output=ROOT/"migrate_production_plan_only.sql";output.write_bytes(result)
    manifest={"state":"PRIVATE_SCOPED_PRODUCTION_LOADER_NOT_EXECUTED","sourcePath":str(SOURCE),"sourceSha256":SOURCE_SHA,
        "outputPath":str(output),"outputSha256":sha(result),"outputBytes":len(result),"productionPlans":"INCLUDED",
        "productionPlanItems":"INCLUDED","v913ExactSourceRegistration":"UNCHANGED","productionCosts":"SKIPPED_USER",
        "costStage":"EMPTY_SCHEMA_ONLY","costDerivedMasterStubs":False,"refreshProductionMonthlyMv":True,"actualDatabase":"NOT_RUN"}
    (ROOT/"split-manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(manifest,ensure_ascii=False))
if __name__=="__main__":main()
