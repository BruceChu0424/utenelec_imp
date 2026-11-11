from pathlib import Path
import argparse,json
p=argparse.ArgumentParser();p.add_argument('--before',required=True);p.add_argument('--after',required=True);p.add_argument('--seed',required=True);p.add_argument('--out',required=True);a=p.parse_args()
before=json.loads(Path(a.before).read_text(encoding='utf-8-sig'));after=json.loads(Path(a.after).read_text(encoding='utf-8-sig'));seed=json.loads(Path(a.seed).read_text(encoding='utf-8-sig'));out=Path(a.out)
if out.exists():raise SystemExit('Preserve previous comparison')
old_ids={s['id'] for s in before['styles']};new_styles=[s for s in after['styles'] if s['id'] not in old_ids]
old_accounts={s['id'] for s in before['accounts']};new_accounts=[s for s in after['accounts'] if s['id'] not in old_accounts]
expected={r['candidateStyleId'] for r in seed['roleCandidates'] if 'candidateStyleId' in r}
checks={'roleMappingsByteEquivalent':before['roles']==after['roles'],'oldStylesUnchanged':before['styles']==[s for s in after['styles'] if s['id'] in old_ids],
    'oldAccountsSelectedFieldsUnchanged':before['accounts']==[s for s in after['accounts'] if s['id'] in old_accounts],
    'onlyExpectedNewStyles':{s['id'] for s in new_styles}==expected,'onlyExpectedNewActor':len(new_accounts)==1 and new_accounts[0]['id']==seed['syntheticFinance']['userId'],
    'newStylesCreatedByOrdinaryFinance':all(s['created_by']==seed['syntheticFinance']['userId'] for s in new_styles),
    'businessCountsUnchanged':before['businessCounts']==after['businessCounts']}
result={'status':'prep; no UI mapping or GL generation performed','checks':checks,'addedStyleCount':len(new_styles),'addedActorCount':len(new_accounts)}
out.write_bytes(json.dumps(result,ensure_ascii=False,indent=2).encode('utf8'));print(json.dumps(result,ensure_ascii=True))
if not all(checks.values()):raise SystemExit('Review actual before/after differences; do not fake a pass')
