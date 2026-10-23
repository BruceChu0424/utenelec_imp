#!/usr/bin/env python3
"""Validate the exact legacy BOM projection and emit a transaction target gate.

Kahn and iterative SCC traversal use no recursion. Filtering mirrors
migrate_goods_bom.sql, including its numeric(18,5) staging precision and V903
disabled-component policy. The generated SQL proves the target edge set in both
directions, its quantities, exclusions and canonical SHA-256; it creates no BOM.
"""
from __future__ import annotations

import argparse
from collections import Counter,defaultdict,deque
import csv
from decimal import Decimal,InvalidOperation,ROUND_HALF_UP,localcontext
import hashlib
import json
from pathlib import Path
import re

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
SCALE=Decimal('0.00001')


def digest(path: Path) -> str:
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def integer(value,*,where: str) -> int:
    if not re.fullmatch(r'-?[0-9]+',str(value).strip()):raise ValueError('Invalid integer identity at '+where)
    result=int(value)
    if not -(2**31)<=result<2**31:raise ValueError('Identity outside PostgreSQL int domain at '+where)
    return result


def quantity(value,*,where: str) -> Decimal|None:
    if value is None or str(value).strip()=='':return None
    try:
        with localcontext() as context:
            context.prec=80
            parsed=Decimal(value)
            if not parsed.is_finite():raise ValueError('Nonfinite BOM quantity at '+where)
            rounded=parsed.quantize(SCALE,rounding=ROUND_HALF_UP)
            if abs(rounded)>=Decimal(10)**13:raise ValueError('BOM quantity exceeds numeric(18,5) at '+where)
            return rounded
    except InvalidOperation as error:
        raise ValueError('Invalid numeric quantity at '+where) from error


def flag(value) -> bool:
    normalized=str(value or '').strip().casefold()
    if normalized in ('','false','f','0'):return False
    if normalized in ('true','t','1'):return True
    raise ValueError('Invalid operational-master boolean')


def read_csv(path: Path) -> list[dict]:
    with path.open(encoding='utf-8-sig',newline='') as stream:
        reader=csv.DictReader(stream,delimiter='|')
        if not reader.fieldnames or len(reader.fieldnames)!=len(set(reader.fieldnames)):raise ValueError('Invalid CSV header: '+path.name)
        records=list(reader)
        if any(None in row or any(value is None for value in row.values()) for row in records):raise ValueError('Invalid CSV width: '+path.name)
        return records


def cyclic_components(graph: dict[int,set[int]],remaining: set[int]) -> list[list[int]]:
    """Iterative Kosaraju, only for Kahn's nonempty cyclic residue."""
    if not remaining:return []
    visited,finished=set(),[]
    for root in remaining:
        if root in visited:continue
        visited.add(root);stack=[(root,iter(graph.get(root,())))]
        while stack:
            node,children=stack[-1]
            try:child=next(children)
            except StopIteration:
                stack.pop();finished.append(node);continue
            if child in remaining and child not in visited:
                visited.add(child);stack.append((child,iter(graph.get(child,()))))
    reverse=defaultdict(set)
    for parent in remaining:
        for child in graph.get(parent,()):
            if child in remaining:reverse[child].add(parent)
    visited.clear();cycles=[]
    for root in reversed(finished):
        if root in visited:continue
        component=[];pending=[root];visited.add(root)
        while pending:
            node=pending.pop();component.append(node)
            for parent in reverse[node]:
                if parent not in visited:visited.add(parent);pending.append(parent)
        if len(component)>1 or root in graph.get(root,set()):cycles.append(sorted(component))
    return sorted(cycles,key=lambda component:component[0])


def inspect(goods: list[dict],bom: list[dict]) -> dict:
    masters={}
    for rowno,row in enumerate(goods,2):
        identity=integer(row.get('legacy_id'),where='goods row '+str(rowno))
        if identity in masters:raise ValueError('Repeated final goods identity')
        masters[identity]=row
    operational={identity for identity,row in masters.items() if not flag(row.get('is_deleted')) and not flag(row.get('auto_created'))}
    edges,excluded=[],[]
    ids=Counter();pairs=defaultdict(list);graph=defaultdict(set);nodes=set()
    for rowno,row in enumerate(bom,2):
        identity=integer(row.get('legacy_id'),where='BOM row '+str(rowno))
        parent=integer(row.get('goods_legacy_id'),where='BOM parent '+str(identity))
        child=integer(row.get('component_legacy_id'),where='BOM component '+str(identity))
        qty=quantity(row.get('qty'),where='BOM edge '+str(identity));ids[identity]+=1
        edge=dict(legacy_id=identity,parent_legacy_id=parent,component_legacy_id=child,qty=format(qty,'.5f') if qty is not None else None)
        if qty is None or qty<=0:reason='EXCLUDED_NON_POSITIVE_QTY'
        elif parent not in operational or child not in operational:reason='EXCLUDED_NON_OPERATIONAL_MASTER'
        elif masters[child].get('status')=='禁用':reason='EXCLUDED_DISABLED_COMPONENT'
        else:reason=None
        if reason:excluded.append(dict(edge,reason=reason));continue
        edges.append(edge);pairs[parent,child].append(identity);graph[parent].add(child);nodes.update((parent,child))
    duplicates=[dict(parent_legacy_id=pair[0],component_legacy_id=pair[1],source_legacy_ids=sorted(identities)) for pair,identities in pairs.items() if len(identities)>1]
    duplicate_ids=sorted(identity for identity,count in ids.items() if count>1)
    indegrees=dict.fromkeys(nodes,0)
    for children in graph.values():
        for child in children:indegrees[child]+=1
    roots=[node for node,degree in indegrees.items() if degree==0]
    pending=deque(roots);depth=dict.fromkeys(roots,0);processed=0
    while pending:
        node=pending.popleft();processed+=1
        for child in graph.get(node,()):
            depth[child]=max(depth.get(child,0),depth[node]+1)
            indegrees[child]-=1
            if indegrees[child]==0:pending.append(child)
    cycles=cyclic_components(graph,{node for node,degree in indegrees.items() if degree>0})
    ordered=sorted(edges,key=lambda edge:edge['legacy_id'])
    graph_sha=hashlib.sha256(''.join(f"{edge['legacy_id']}:{edge['parent_legacy_id']}:{edge['component_legacy_id']}:{edge['qty']}\n" for edge in ordered).encode()).hexdigest()
    reasons=Counter(edge['reason'] for edge in excluded)
    summary=dict(valid=not(cycles or duplicates or duplicate_ids),source_edges=len(bom),retained_edges=len(edges),
        excluded_edges=len(excluded),exclusions_by_reason=dict(reasons),source_conservation=len(bom)==len(edges)+len(excluded),
        operational_master_nodes=len(operational),graph_nodes=len(nodes),graph_roots=len(roots),
        isolated_operational_master_nodes=len(operational-nodes),processed_nodes=processed,
        max_depth_edges=max(depth.values(),default=0) if not cycles else None,
        max_layers=(max(depth.values(),default=0)+1 if nodes else 0) if not cycles else None,
        cyclic_components=len(cycles),duplicate_active_parent_component_groups=len(duplicates),duplicate_source_ids=duplicate_ids,
        graph_sha256=graph_sha,canonical_line='legacy_id:parent_legacy_id:component_legacy_id:qty_fixed_5\n ordered by numeric legacy_id',
        quantity_policy='PostgreSQL numeric(18,5), half away from zero',production_acceptance=False)
    return dict(summary=summary,edges=ordered,excluded=sorted(excluded,key=lambda edge:edge['legacy_id']),cycles=cycles,duplicates=duplicates)


def inserts(table: str,records: list[dict],fields: list[str]) -> str:
    statements=[]
    for offset in range(0,len(records),1000):
        values=[]
        for record in records[offset:offset+1000]:
            cells=[]
            for field in fields:
                value=record[field]
                if value is None:cells.append('NULL')
                elif field=='reason':cells.append("'"+value+"'")
                else:cells.append(str(value))
            values.append('('+','.join(cells)+')')
        statements.append('INSERT INTO '+table+' VALUES\n'+',\n'.join(values)+';\n')
    return ''.join(statements)


def render_sql(result: dict,goods_sha: str,bom_sha: str) -> str:
    summary=result['summary']
    if not summary['valid']:
        return "DO $$ BEGIN RAISE EXCEPTION 'BOM topology source validation rejected cycles or duplicate active identities'; END $$;\n"
    sql="""-- Static reviewed topology gate; caller owns the full bootstrap transaction.
-- No BOM rows, quantities, actors or workflow policies are changed here.
CREATE TEMP TABLE expected_bom_topology_edges(legacy_id int PRIMARY KEY,parent_legacy_id int,component_legacy_id int,qty numeric(18,5));
CREATE TEMP TABLE expected_bom_topology_exclusions(legacy_id int PRIMARY KEY,parent_legacy_id int,component_legacy_id int,qty numeric(18,5),reason text);
"""
    fields=['legacy_id','parent_legacy_id','component_legacy_id','qty']
    sql+=inserts('expected_bom_topology_edges',result['edges'],fields)
    sql+=inserts('expected_bom_topology_exclusions',result['excluded'],fields+['reason'])
    sql+="""DO $$ BEGIN
 IF (SELECT count(*) FROM goods_bom_items WHERE NOT is_deleted)<>(SELECT count(*) FROM expected_bom_topology_edges)
 OR EXISTS (SELECT 1 FROM expected_bom_topology_edges expected
  LEFT JOIN goods_bom_items actual ON actual.legacy_id=expected.legacy_id
  LEFT JOIN goods parent ON parent.id=actual.goods_id
  LEFT JOIN goods component ON component.id=actual.component_goods_id
  WHERE actual.id IS NULL OR actual.is_deleted OR parent.legacy_id IS DISTINCT FROM expected.parent_legacy_id
   OR component.legacy_id IS DISTINCT FROM expected.component_legacy_id OR actual.qty IS DISTINCT FROM expected.qty
   OR parent.is_deleted OR parent.auto_created OR component.is_deleted OR component.auto_created OR component.status='禁用')
 OR EXISTS (SELECT 1 FROM goods_bom_items actual LEFT JOIN expected_bom_topology_edges expected ON expected.legacy_id=actual.legacy_id
  WHERE NOT actual.is_deleted AND expected.legacy_id IS NULL) THEN
  RAISE EXCEPTION 'BOM target edge identities or quantities differ from the validated acyclic source graph';
 END IF;
 IF (SELECT count(*) FROM bootstrap_bom_exclusions WHERE source_file='goods_bom.csv')<>(SELECT count(*) FROM expected_bom_topology_exclusions)
 OR EXISTS (SELECT 1 FROM expected_bom_topology_exclusions expected
  LEFT JOIN bootstrap_bom_exclusions actual ON actual.source_file='goods_bom.csv' AND actual.source_legacy_id=expected.legacy_id
  WHERE actual.source_legacy_id IS NULL OR actual.parent_legacy_id IS DISTINCT FROM expected.parent_legacy_id
   OR actual.component_legacy_id IS DISTINCT FROM expected.component_legacy_id OR actual.source_qty IS DISTINCT FROM expected.qty
   OR actual.reason IS DISTINCT FROM expected.reason)
 OR EXISTS (SELECT 1 FROM bootstrap_bom_exclusions actual LEFT JOIN expected_bom_topology_exclusions expected ON expected.legacy_id=actual.source_legacy_id
  WHERE actual.source_file='goods_bom.csv' AND expected.legacy_id IS NULL) THEN
  RAISE EXCEPTION 'BOM target exclusions differ from exact validated source dispositions';
 END IF;
END $$;
CREATE TEMP TABLE verified_bom_topology_hash AS
SELECT encode(digest(convert_to(COALESCE(string_agg(actual.legacy_id::text||':'||parent.legacy_id::text||':'||component.legacy_id::text||':'||actual.qty::text||E'\\n','' ORDER BY actual.legacy_id),''),'UTF8'),'sha256'),'hex') AS graph_sha256
FROM goods_bom_items actual JOIN goods parent ON parent.id=actual.goods_id JOIN goods component ON component.id=actual.component_goods_id
WHERE NOT actual.is_deleted;
"""
    sql+="DO $$ BEGIN IF (SELECT graph_sha256 FROM verified_bom_topology_hash)<> '"+summary['graph_sha256']+"' THEN RAISE EXCEPTION 'BOM target graph SHA differs from its validated source'; END IF; END $$;\n"
    record=dict(summary,source_goods_sha256=goods_sha,source_bom_sha256=bom_sha,target_edge_identity_verified=True,target_exclusion_identity_verified=True)
    encoded=json.dumps(record,ensure_ascii=True,separators=(',',':')).replace("'","''")
    sql+="UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary||jsonb_build_object('bomTopology','"+encoded+"'::jsonb) WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid AND status='RUNNING';\n"
    sql+="DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM legacy_migration_runs WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid AND status='RUNNING' AND reconciliation_summary->'bomTopology'->>'graph_sha256'='"+summary['graph_sha256']+"') THEN RAISE EXCEPTION 'BOM topology proof requires the current running import'; END IF; END $$;\n"
    sql+="SELECT 'BOM topology verified' AS check_name,graph_sha256 FROM verified_bom_topology_hash;\n"
    return sql


def write_csv(path: Path,rows: list[dict],fields: list[str]):
    with path.open('w',encoding='utf-8',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=fields,delimiter='|',lineterminator='\n');writer.writeheader()
        for row in rows:writer.writerow({field:json.dumps(row[field]) if isinstance(row.get(field),list) else row.get(field) for field in fields})


def prepare(goods_csv: Path,bom_csv: Path,output: Path) -> dict:
    before={str(path.resolve()):digest(path) for path in (goods_csv,bom_csv)}
    result=inspect(read_csv(goods_csv),read_csv(bom_csv));output.mkdir(parents=True,exist_ok=True)
    (output/'bom_topology_summary.json').write_text(json.dumps(result['summary'],ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (output/'bom_cycle_components.json').write_text(json.dumps(result['cycles'],indent=2)+'\n',encoding='utf-8')
    fields=['legacy_id','parent_legacy_id','component_legacy_id','qty']
    write_csv(output/'bom_expected_edge_audit.csv',result['edges'],fields)
    write_csv(output/'bom_expected_exclusion_audit.csv',result['excluded'],fields+['reason'])
    write_csv(output/'bom_duplicate_active_pairs.csv',result['duplicates'],['parent_legacy_id','component_legacy_id','source_legacy_ids'])
    (output/'goods_bom_topology.sql').write_text(render_sql(result,before[str(goods_csv.resolve())],before[str(bom_csv.resolve())]),encoding='utf-8')
    if any(digest(Path(path))!=sha for path,sha in before.items()):raise ValueError('BOM topology input changed during validation')
    evidence=[HERE/'migrate_goods_bom.sql',ROOT/'server/src/main/resources/db/migration/V79__goods_bom_items.sql']
    manifest=dict(format='legacy-bom-topology-v1',valid=result['summary']['valid'],generator_sha256=digest(Path(__file__)),
        inputs=[dict(path=path,sha256=sha) for path,sha in before.items()],
        evidence_sources=[dict(path=str(path.resolve()),sha256=digest(path)) for path in evidence],
        outputs=[dict(file=path.name,sha256=digest(path),bytes=path.stat().st_size) for path in sorted(output.iterdir()) if path.is_file() and path.name!='bom_topology_manifest.json'])
    (output/'bom_topology_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return result['summary']


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--goods-csv',type=Path,required=True);parser.add_argument('--bom-csv',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True);args=parser.parse_args()
    summary=prepare(args.goods_csv,args.bom_csv,args.output_dir)
    print(json.dumps(summary,ensure_ascii=False,indent=2));return 0 if summary['valid'] else 2


if __name__=='__main__':
    raise SystemExit(main())
