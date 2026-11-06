from pathlib import Path
import hashlib,json,subprocess,re
from datetime import datetime,timezone
repo=Path(__file__).resolve().parents[4]
out=Path(__file__).resolve().parent
review=json.loads((out/'preview.json').read_text(encoding='utf-8'))
main=review['main'];prefix='server/src/main/resources/db/migration/'
sha=lambda b:hashlib.sha256(b).hexdigest()
assert subprocess.check_output(['git','-C','D:/Projects/uten_imp','rev-parse','HEAD'],text=True).strip()==main
def replace(text,old,new,n=1):
    assert text.count(old)==n,(old[:120],text.count(old),n)
    return text.replace(old,new)
def original(i,side='main'):return (out/str(i)/side).read_text(encoding='utf-8')
final={};notes={}
for row in review['rows']:
    p=row['path'];path=repo/p;actual=path.read_bytes() if path.exists() else None
    assert (sha(actual) if actual is not None else None)==row['task'],p
    if actual is not None:
        dest=out/'original-task'/p;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(actual)
    if p.startswith(prefix) or p=='docs/数据迁移/README.md':continue
    if row['classification']=='task-equals-base':
        final[p]=subprocess.check_output(['git','show',main+':'+p]);notes[p]='Task byte-equal6fb: adopt exact fa Main bytes'
    elif row.get('mergeExit')==0:
        final[p]=(repo/row['preview']/'merged').read_bytes();notes[p]='Non-overlapping three-way combination; both sides retained'

# Main's lineage planning and frozen inheritance retain their exact order. Task's
# original weight evidence is captured from the old row before the same insert.
p='server/src/main/java/com/uten/imp/features/documents/DocumentUnapprovalService.java'
t=original(3)
t=replace(t,'import com.uten.imp.application.port.DocumentUnapprovalPort;','import com.uten.imp.application.port.DocumentUnapprovalPort;\nimport com.uten.imp.application.port.BusinessNumericInputEvidencePort;')
t=replace(t,'    private final ObjectMapper json;','    private final ObjectMapper json;\n    private final BusinessNumericInputEvidencePort numericInputEvidence;')
t=replace(t,'            ObjectMapper json) {','            ObjectMapper json, BusinessNumericInputEvidencePort numericInputEvidence) {')
t=replace(t,'this.tx = tx; this.json = json;','this.tx = tx; this.json = json;\n        this.numericInputEvidence = numericInputEvidence;')
t=replace(t,'        for (var line : lines.entrySet()) {\n            UUID id=line.getKey(),newId=line.getValue();','        String weightKind=adapter.receiptWeightOwnerKind();\n        for (var line : lines.entrySet()) {\n            UUID id=line.getKey(),newId=line.getValue();\n            Object originalWeight=weightKind==null?null:em.createNativeQuery("SELECT weight FROM "+spec.table()+" WHERE id=:oldLine")\n                    .setParameter("oldLine",id).getSingleResult();\n            java.math.BigDecimal weight=com.uten.imp.common.util.NativeValueConverters.toBigDecimal(originalWeight);')
t=replace(t,'            if(query.executeUpdate()!=1) throw new ApiException(ErrorCode.CONFLICT,"反审明细已变化，本次未生成草稿");','            // Keep the original raw input/evidence and bind recorded kilograms to this new action.\n            if(weightKind!=null) com.uten.imp.common.numeric.DocumentWeightEvidence.capture(\n                    numericInputEvidence,weightKind,draftId,newId,"actualWeightKg",weight,weight);\n            if(query.executeUpdate()!=1) throw new ApiException(ErrorCode.CONFLICT,"反审明细已变化，本次未生成草稿");')
final[p]=t.encode();notes[p]='Main lineage-before-copy and frozen-source branch exact; Task new-generation weight evidence retained'

p='server/src/main/java/com/uten/imp/features/finance/application/FinanceApplicationService.java'
t=original(6)
base=original(6,'base');task=original(6,'task')
b=next(s for s in base.splitlines() if 'String filter=switch(queue)' in s)
q=next(s for s in task.splitlines() if 'String filter=switch(queue)' in s)
t=replace(t,b,q);final[p]=t.encode();notes[p]='Exact Main detail ACL/edit-only source behavior plus exact Task lifecycle queue predicates'

p='server/src/test/java/com/uten/imp/businesschain/GiftUnitRateConservationEndToEndTest.java'
t=original(22)
anchor='        F fresh=fixture();UUID untouched=receipt(fresh,"1","1");'
extra='''        FrozenUnapprovalInputs.unapprove(db,unapproval,"purchaseReturn",activeReturn,
                new DocumentUnapprovalService.UnapproveRequest("gift-rate-active-unapprove-"+activeReturn,"原退货撤回后验证同源收货恢复"));
        assertThat(receipts.unapprovalEligibility(received).eligible()).isTrue();
        receipts.reverse(received);
        assertThat(stock(f)).isZero();assertThat(value(f)).isZero();assertThat(ap(received)).isZero();
        assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",received)).isPositive();
        assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",returned)).isPositive();
        evidence(f,received,returnDraft.getId(),"COMPLETED_SAME_ISSUE_RETURN_REVERSES_ORIGINAL_RECEIPT",Map.of("stockQty","0","stockValue","0","AP","0","domainReversal","V1008 proved original issue/pool identity; history retained"));
'''
t=replace(t,anchor,extra+anchor);final[p]=t.encode();notes[p]='All Main frozen clone/rollback tests plus Task actual completed same-source receipt reversal/history assertions'

p='server/src/test/java/com/uten/imp/businesschain/ProcurementUnapprovalEligibilityEndToEndTest.java'
t=original(28)
anchor='        assertThatThrownBy(()->unapprove("purchaseReceipt",id)).isInstanceOf(com.uten.imp.common.web.ApiException.class);assertThat(facts()).isEqualTo(before);'
t=replace(t,anchor,anchor+'''
        unapprove("purchaseReturn",activeReturn);allowedWithoutWrites(()->receipts.unapprovalEligibility(id));unapprove("purchaseReceipt",id);
        assertThat(stock(f)).isZero();assertThat(value(f)).isZero();assertThat(ap(id)).isZero();
        assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",id)).isPositive();
        assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",returned)).isPositive();''')
anchor='        SC f=subcontractFixture(false);allowedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()));unapprove("subcontractReceipt",f.receipt());'
t=replace(t,anchor,'''        SC f=subcontractFixture(false);allowedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()));UUID draft=unapprove("subcontractReceipt",f.receipt());
        assertThat(number("SELECT original_decimal::numeric FROM business_numeric_input_evidence WHERE owner_kind='SUBCONTRACT_RECEIPT' AND owner_id=? AND field_key='actualWeightKg'",draft)).isEqualByComparingTo("10");
        assertThat(number("SELECT count(DISTINCT source_action_id) FROM business_numeric_input_evidence WHERE owner_kind='SUBCONTRACT_RECEIPT' AND owner_id IN (?,?) AND field_key='actualWeightKg'",f.receipt(),draft)).isEqualByComparingTo("2");''')
anchor='        blockedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()),"退货");\n    }'
t=replace(t,anchor,'''        blockedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()),"退货");
        unapprove("subcontractReturn",activeReturn);allowedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()));unapprove("subcontractReceipt",f.receipt());
        assertThat(ap(f.receipt())).isZero();
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",f.w().goodsE())).isZero();
        assertThat(number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?",f.w().goodsE())).isZero();
        assertThat(number("SELECT SUM(issue.consumed_qty) FROM subcontract_material_issue_items issue WHERE issue.order_item_id=?",f.orderItem())).isZero();
        assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",f.receipt())).isPositive();
        assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",id)).isPositive();
    }''')
t=replace(t,'receiptLine.setQty(BigDecimal.TEN);receiptLine.setOrderItemId(orderItem);','receiptLine.setQty(BigDecimal.TEN);receiptLine.setWeight(BigDecimal.TEN);receiptLine.setOrderItemId(orderItem);')
final[p]=t.encode();notes[p]='All Main frozen/atomic/edit-resubmit tests plus Task same-source terminal conservation and independent new weight action evidence'

p='server/src/test/java/com/uten/imp/features/finance/application/FinanceApplicationsPostgresTest.java'
t=original(38)
# Main now prepares the true1039 graph and migrates before ORM. Restore Task's
# queue cases against the unchanged native bodies rather than a second staged DB.
for old,new in [
('login(w.owner);assertThat(applications.list("mine",null,1,20).get("total")).isEqualTo(1L);','login(w.owner);assertThat(queueIds("mine")).doesNotContain(id.toString());assertThat(queueIds("history")).contains(id.toString());'),
('        assertThatThrownBy(()->db.update("UPDATE finance_application_nodes SET status=\'APPROVED\' WHERE application_id=? AND submission_round=1 AND step_no=1",rejected))','        login(w.owner);assertThat(queueIds("mine")).contains(id.toString(),rejected.toString());assertThat(queueIds("history")).doesNotContain(id.toString(),rejected.toString());\n        assertThatThrownBy(()->db.update("UPDATE finance_application_nodes SET status=\'APPROVED\' WHERE application_id=? AND submission_round=1 AND step_no=1",rejected))'),
('        approvePayment(w,id);\n        assertThat(db.queryForObject','        approvePayment(w,id);\n        login(w.owner);assertThat(queueIds("mine")).contains(id.toString());assertThat(queueIds("history")).doesNotContain(id.toString());\n        login(payer);assertThat(queueIds("payment")).contains(id.toString());\n        assertThat(db.queryForObject'),
('try{start.await();return applications.execute(id,execute);}','try{start.await();assertThat(db.queryForObject("SELECT current_database()",String.class)).isEqualTo(PG.getDatabaseName());return applications.execute(id,execute);}'),
('        assertThatThrownBy(()->applications.reverse(id,reason(confirmed,"真实付款需要按原顺序撤回")))','        assertThat(queueIds("payment")).doesNotContain(id.toString());assertThat(queueIds("history")).contains(id.toString());\n        assertThatThrownBy(()->applications.reverse(id,reason(confirmed,"真实付款需要按原顺序撤回")))'),
('var reversed=applications.reverse(id,reason(unconfirmed,"按原付款资金及GL对称撤销"));assertThat(reversed.get("status")).isEqualTo("REVERSED");','var reversed=applications.reverse(id,reason(unconfirmed,"按原付款资金及GL对称撤销"));assertThat(reversed.get("status")).isEqualTo("REVERSED");\n        login(w.owner);assertThat(queueIds("mine")).contains(id.toString());assertThat(queueIds("history")).doesNotContain(id.toString());login(payer);'),
('    private void approvePayment(World w,UUID id)','    private Set<String> queueIds(String queue){return ((List<?>)applications.list(queue,null,1,100).get("rows")).stream().map(row->((Map<?,?>)row).get("id").toString()).collect(java.util.stream.Collectors.toSet());}\n    private void approvePayment(World w,UUID id)')]: t=replace(t,old,new)
final[p]=t.encode();notes[p]='All Main stronger raw-history/ACL/revoke/unknown-event assertions and true preORM1039 fixture retained; Task lifecycle queues and four-worker owned DB assertion retained'

# Every source path was CAS checked above. Keep SQL moves distinct from Main raw
# adoption; no committed SQL is changed and the original expense body is archived.
migrations=repo/prefix
moves={'V1067__verified_legacy_quantity_adoption.sql':'V1072__verified_legacy_quantity_adoption.sql','V1068__legacy_return_quantity_source_proofs.sql':'V1073__legacy_return_quantity_source_proofs.sql','V1071__execution_workbench_top_level_product_caliber.sql':'V1074__execution_workbench_top_level_product_caliber.sql'}
sql_receipt=[]
for old,new in moves.items():
    path=migrations/old;data=path.read_bytes();dest=out/'original-task'/prefix/old;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
    assert not (migrations/new).exists(),new
    if old.startswith('V1067__'):
        text=data.decode()
        text=replace(text,"anchor text:=E'BEGIN\\n IF TG_OP=''INSERT'' THEN'","anchor text:=E' IF TG_OP=''INSERT'' THEN'")
        text=replace(text,"replacement:=E'BEGIN\\n IF TG_OP=''INSERT'' AND TG_TABLE_SCHEMA=''public'' AND NEW.legacy_id IS NOT NULL\\n'","replacement:=E' IF TG_OP=''INSERT'' AND TG_TABLE_SCHEMA=''public'' AND NEW.legacy_id IS NOT NULL\\n'")
        text=replace(text,"anchor text:=E'BEGIN\\n IF NEW.weight IS NULL'","anchor text:=E' IF NEW.weight IS NULL'")
        text=replace(text,"replacement:=E'BEGIN\\n IF TG_OP=''INSERT'' AND TG_TABLE_SCHEMA=''public'' AND NEW.quantity_adoption_version=1\\n'","replacement:=E' IF TG_OP=''INSERT'' AND TG_TABLE_SCHEMA=''public'' AND NEW.quantity_adoption_version=1\\n'")
        data=text.encode()
    (migrations/new).write_bytes(data);path.unlink();sql_receipt.append({'old':old,'new':new,'beforeSha256':sha(dest.read_bytes()),'afterSha256':sha(data)})
retired=migrations/'V1070__expense_payment_reversal_event_contract.sql';dest=out/'original-task'/prefix/retired.name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(retired.read_bytes());retired.unlink()
for row in review['rows']:
    if row['path'].startswith(prefix):final[row['path']]=subprocess.check_output(['git','show',main+':'+row['path']]);notes[row['path']]='Exact committed Main SQL bytes'
for p,data in final.items():(repo/p).parent.mkdir(parents=True,exist_ok=True);(repo/p).write_bytes(data)
rows=[]
for row in review['rows']:
    p=row['path']
    if p in final:rows.append({**row,'finalSha256':sha(final[p]),'resolution':notes[p]})
receipt={'capturedAtUtc':datetime.now(timezone.utc).isoformat(),'baseMain':review['base'],'currentMain':main,'sourceOnlyNoMainIndexCommitPushOrDBWrites':True,'paths':rows,'sqlMoves':sql_receipt,'retiredUnappliedExpenseBodySha256':sha(dest.read_bytes()),'remainingManualPath':'docs/数据迁移/README.md','fourSemanticAllowlistUnchanged':True}
(out/'source-composition-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
