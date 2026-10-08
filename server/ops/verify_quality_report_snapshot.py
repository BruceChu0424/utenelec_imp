#!/usr/bin/env python3
"""Read-only host and Linux-volume verification before/after a performance side."""
import argparse
import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path
import re

SPEC = importlib.util.spec_from_file_location("quality_report_runner", Path(__file__).with_name("run_quality_report_performance.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

LINUX_HASH = r'''
import hashlib,json,pathlib
def tree(folder):
    root=pathlib.Path(folder)
    files={}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            sha=hashlib.sha256()
            with path.open("rb") as source:
                for block in iter(lambda:source.read(1048576),b""):sha.update(block)
            files[path.relative_to(root).as_posix()]=sha.hexdigest()
    if not files:raise RuntimeError("Empty artifact tree")
    return hashlib.sha256(json.dumps(files,sort_keys=True,separators=(",",":")).encode()).hexdigest()
result={side+kind:tree("/runs/"+side+"/"+folder)
 for side in ("baseline","candidate") for kind,folder in (("Classes","classes"),("Tests","test-classes"))}
result["projectPomSha256"]=hashlib.sha256(pathlib.Path("/runs/project/server/pom.xml").read_bytes()).hexdigest()
print(json.dumps(result))
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id",required=True)
    parser.add_argument("--side",required=True,choices=("baseline","candidate"))
    parser.add_argument("--stage",required=True,choices=("before","after"))
    parser.add_argument("--baseline",type=Path,default=runner.ROOT/"server/target-perf-baseline")
    parser.add_argument("--candidate",type=Path,default=runner.ROOT/"server/target-quality-safety-final")
    args=parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,39}",args.run_id):parser.error("Invalid run id")
    output=runner.ROOT/"server/target-performance-linux"/args.run_id
    manifest=json.loads((output/"manifest.json").read_text(encoding="utf-8"))
    if manifest["state"]!="PREPARED":raise ValueError("Artifact preparation is incomplete")
    checks=output/"checks";checks.mkdir(exist_ok=True)
    path=checks/(args.side+"-"+args.stage+".json")
    if path.exists():raise ValueError("Existing snapshot checks cannot be overwritten")
    receipt={"side":args.side,"stage":args.stage,"startedAtUtc":datetime.now(timezone.utc).isoformat(),"state":"CHECKING"}
    runner.write_json(path,receipt)
    try:
        runner.validate_topology(manifest)
        source=runner.workspace_source_identity()
        if source!=manifest["sourceIdentity"]:raise ValueError("Host main/test/pom source identity changed")
        host={"baselineClasses":runner.tree_identity(runner.scoped(args.baseline)/"classes")["sha256"],
              "candidateClasses":runner.tree_identity(runner.scoped(args.candidate)/"classes")["sha256"],
              "sharedTestClasses":runner.tree_identity(runner.scoped(args.candidate)/"test-classes")["sha256"]}
        for field,value in host.items():
            if value!=manifest[field]["sha256"]:raise ValueError("Host compiled tree changed: "+field)
        if manifest["workVolume"]!="uten-performance-"+args.run_id+"-work":raise ValueError("Unexpected volume")
        linux=json.loads(runner.docker("run","--rm","--pull=never","--user=0:0","--network","none","--mount",
                "type=volume,source="+manifest["workVolume"]+",target=/runs,readonly","--entrypoint","/usr/bin/python3",
                manifest["image"],"-c",LINUX_HASH))
        for side in ("baseline","candidate"):
            if linux[side+"Classes"]!=manifest[side+"Classes"]["sha256"]:raise ValueError("Linux main classes differ: "+side)
            if linux[side+"Tests"]!=manifest["sharedTestClasses"]["sha256"]:raise ValueError("Linux tests differ: "+side)
        if linux["projectPomSha256"]!=manifest["projectPomSha256"]:raise ValueError("Executed Maven project changed")
        receipt.update(state="VERIFIED",sourceIdentity=source,hostTrees=host,linuxTrees=linux,
                       scope="complete host server/src/main, server/src/test and pom; complete compiled host and executed Linux main/test trees; deploy/docs outside this source scope")
    except Exception as failure:
        receipt.update(state="FAILED",error=str(failure))
        runner.write_json(path,receipt)
        raise
    receipt["finishedAtUtc"]=datetime.now(timezone.utc).isoformat()
    runner.write_json(path,receipt)
    print("Snapshot VERIFIED:",path)


if __name__=="__main__":main()
