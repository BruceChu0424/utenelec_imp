import difflib,hashlib,json
from pathlib import Path
from datetime import datetime,timezone
base=Path(__file__).resolve().parent;root=base.parents[3];dest=base/'gift-physical-weight-repair';assert not dest.exists();dest.mkdir()
path='server/src/test/java/com/uten/imp/businesschain/GiftPhysicalConservationEndToEndTest.java';before=(root/path).read_bytes();text=before.decode('utf-8-sig');nl='\r\n' if '\r\n' in text else '\n'
anchor='        var request=new DocumentUnapprovalService.UnapproveRequest("gift-unapprove-"+receipt,"收费和免费实物同代际守恒");'
assert text.count(anchor)==1
prefix='''        UUID originalItem=receipts.detail(receipt).getItems().getFirst().getId();
        String evidenceSql="SELECT jsonb_agg(to_jsonb(evidence) ORDER BY id)::text FROM business_numeric_input_evidence evidence WHERE owner_kind='PURCHASE_RECEIPT' AND owner_id=? AND source_row_id=? AND field_key='actualWeightKg'";
        String originalEvidence=db.queryForObject(evidenceSql,String.class,receipt,originalItem);
        assertThat(originalEvidence).isNotNull();
        assertThat(db.queryForObject("SELECT original_decimal FROM business_numeric_input_evidence WHERE owner_kind='PURCHASE_RECEIPT' AND owner_id=? AND source_row_id=? AND field_key='actualWeightKg'",String.class,receipt,originalItem)).isEqualTo("11.0000");
        assertThat(number("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_kind='PURCHASE_RECEIPT' AND owner_id=? AND field_key='actualWeightKg'",receipt)).isEqualByComparingTo("1");
        assertThat(number("SELECT count(DISTINCT source_action_id) FROM business_numeric_input_evidence WHERE owner_kind='PURCHASE_RECEIPT' AND owner_id=? AND field_key='actualWeightKg'",receipt)).isEqualByComparingTo("1");
        assertThat(db.queryForObject("SELECT precision_policy->'choices'='{}'::jsonb AND original_unit->>'code'='KG' AND recorded_unit=original_unit FROM business_numeric_input_evidence WHERE owner_kind='PURCHASE_RECEIPT' AND owner_id=? AND source_row_id=? AND field_key='actualWeightKg'",Boolean.class,receipt,originalItem)).isTrue();
'''.replace('\n',nl)
text=text.replace(anchor,prefix+anchor)
start='        assertThat(number("SELECT original_decimal::numeric FROM business_numeric_input_evidence WHERE owner_kind=\'PURCHASE_RECEIPT\' AND owner_id=? AND source_row_id=? AND field_key=\'actualWeightKg\'",draft.getId(),draft.getItems().getFirst().getId())).isEqualByComparingTo("11");'
end='        assertThat(db.queryForObject("SELECT precision_policy->\'choices\'=\'{}\'::jsonb AND original_unit->>\'code\'=\'KG\' AND recorded_unit=original_unit FROM business_numeric_input_evidence WHERE owner_kind=\'PURCHASE_RECEIPT\' AND owner_id=? AND source_row_id=? AND field_key=\'actualWeightKg\'",Boolean.class,draft.getId(),draft.getItems().getFirst().getId())).isTrue();'
left=text.index(start);right=text.index(end,left)+len(end)
replacement='''        UUID draftItem=draft.getItems().getFirst().getId();
        assertThat(number("SELECT weight FROM purchase_receipt_items WHERE id=?",draftItem)).isEqualByComparingTo("11");
        assertThat(db.queryForObject("SELECT unapproval_source_item_id FROM purchase_receipt_items WHERE id=?",UUID.class,draftItem)).isEqualTo(originalItem);
        assertThat(number("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_id=?",draft.getId())).isZero();
        assertThat(number("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_kind='PURCHASE_RECEIPT' AND owner_id IN (?,?) AND field_key='actualWeightKg'",receipt,draft.getId())).isEqualByComparingTo("1");
        assertThat(number("SELECT count(DISTINCT source_action_id) FROM business_numeric_input_evidence WHERE owner_kind='PURCHASE_RECEIPT' AND owner_id IN (?,?) AND field_key='actualWeightKg'",receipt,draft.getId())).isEqualByComparingTo("1");
        assertThat(db.queryForObject(evidenceSql,String.class,receipt,originalItem)).isEqualTo(originalEvidence);'''.replace('\n',nl)
text=text[:left]+replacement+text[right:]
tail='        assertThat(number("SELECT count(*) FROM procurement_inspection_items WHERE receipt_id=? AND status=\'RESOLVED\'",draft.getId())).isEqualByComparingTo("2");'
assert text.count(tail)==1;text=text.replace(tail,tail+nl+'        assertThat(number("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_id=?",draft.getId())).isZero();'+nl+'        assertThat(db.queryForObject(evidenceSql,String.class,receipt,originalItem)).isEqualTo(originalEvidence);')
after=text.encode('utf-8');(dest/'original.raw').write_bytes(before);(dest/'staged.raw').write_bytes(after)
diff='\n'.join(difflib.unified_diff(before.decode('utf-8').splitlines(),text.splitlines(),fromfile='Current/'+path,tofile='Staged/'+path,n=5,lineterm=''))+'\n';(dest/'review.diff').write_bytes(diff.encode('utf-8'))
support=['server/src/main/java/com/uten/imp/common/numeric/BusinessNumericInputEvidenceService.java','server/src/main/java/com/uten/imp/features/documents/DocumentUnapprovalService.java','server/src/main/java/com/uten/imp/features/purchase/receipt/PurchaseReceiptUnapprovalAdapter.java','server/src/main/resources/db/migration/V1067__inherit_unapproval_frozen_quantity_and_reference_proofs.sql','server/src/test/java/com/uten/imp/common/finance/UnapprovalFrozenAdoptionPostgresTest.java']
result={'atUtc':datetime.now(timezone.utc).isoformat(),'sourceAggregateSha256':json.loads((base/'complete-source-input.json').read_text(encoding='utf-8'))['aggregateSha256'],'path':path,'beforeSha256':hashlib.sha256(before).hexdigest(),'stagedSha256':hashlib.sha256(after).hexdigest(),'diffSha256':hashlib.sha256(diff.encode('utf-8')).hexdigest(),'sourceWritten':False,'failure':'Current original15PG GiftPhysical receiptUnapproval... line111 EmptyResultDataAccessException: obsolete expectation of new cloned weight input; group continues unchanged.','semanticDecision':'Main frozen-source lineage inherits kg; cloning/approval is not a new user input. Preserve original raw11.0000/action1/unit KG/policy plus full original evidence JSON/fingerprint; explicitly assert draft kg11/source item/new-owner evidence0 before and after approve.','unchanged':'All original stock/value/AP/source-counter/idempotency/quantity semantics/two IQC tranches/repeated approve rejection assertions retained; no production/shared helper/SQL changes, no threshold/assertion relaxation.','supportingSourceSha256':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in support}}
(dest/'review.json').write_bytes((json.dumps(result,ensure_ascii=False,indent=2)+'\n').encode('utf-8'));print(json.dumps(result,ensure_ascii=True))
