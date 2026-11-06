import json
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3]
fast=['ExpenseClaimServiceTest','DocumentUnapprovalCapabilityTest','SelectedDocumentProjectionTest','ForwardMigrationSequenceContractTest','LegacyMigrationSafetyContractTest','FlywayChecksumManifestExporterTest','AiUsageAuditControllerSecurityTest','ProcurementApprovalHistoryQueryTest','FulfillmentWorkbenchQueryServiceTest','WarehouseTaskCenterOutputIdentityTest']
pg=['LegacyQuantityUnapprovalCompositionPostgresTest','LegacyQuantityAdoptionCompatibilityPostgresTest','UnapprovalFrozenAdoptionPostgresTest','ProcurementUnapprovalEligibilityEndToEndTest','GiftUnitRateConservationEndToEndTest','GiftPhysicalConservationEndToEndTest','FinanceApplicationsPostgresTest','FinanceUnapprovalEligibilityEndToEndTest','SubcontractMaterialReturnOriginalCostEndToEndTest','InventoryValueOutputRefreshContinuationPostgresTest','DirectMakeDeliveryClosedCreditPostgresTest','ProductionExecutionWorkbenchQueryPostgresTest','LegacyFlywayVersionIdentityPostgresTest','NonFinanceUnapprovalEligibilityEndToEndTest','FinanceDocumentMutationConcurrencyPostgresTest']
source=json.loads((base/'complete-source-input.json').read_text(encoding='utf-8'))
groups={}
for label,names in [('current-fast',fast),('current-pg',pg)]:
    for name in names:
        paths=list((root/'server/src/test/java').rglob(name+'.java'));assert len(paths)==1,(name,paths)
    (base/(label+'-selection.txt')).write_text(','.join(names)+'\n',encoding='utf-8')
    groups[label]={'classes':names,'scope':'Whole classes, no method filtering. Actual XML methods/classes and natural native exit authoritative.'}
(base/'required-targets.json').write_text(json.dumps({'source':source['aggregateSha256'],'groups':groups,'rationale':{'fast':'All actually composed fa callers and exact migration producer/safety/sequence contracts.','pg':'New legacy/unapproval SQL definition and five-loader composition, all six frozen families, actually composed procurement/gift/finance lifecycles, changed adapters in finance/nonfinance/subcontract, original never-executed inventory continuation, immutable closedMAKE and workbench view after full new migration chain, true raw history producer consumer.'},'historicalFailuresRetained':True},indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:len(v['classes']) for k,v in groups.items()}))
