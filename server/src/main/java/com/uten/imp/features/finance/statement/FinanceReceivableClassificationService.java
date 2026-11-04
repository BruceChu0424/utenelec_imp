package com.uten.imp.features.finance.statement;

import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationContracts.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationService.*;
import static com.uten.imp.features.finance.statement.FinanceReceivableClassificationContracts.*;

/** Assigns existing AR cash and offsets to goods/material; never posts money or GL. */
@Service @RequiredArgsConstructor
public class FinanceReceivableClassificationService {
    private final JdbcTemplate db;
    private final FinanceOpenItemClassificationService base;
    private final SecurityContextCurrentUser current;

    @Transactional(readOnly=true)
    public Map<String,Object> receipt(UUID lineId){
        base.read();var result=new LinkedHashMap<>(receiptFact(lineId));
        var source=base.latest("finance_open_item_classification_batches","ledger_id",(UUID)result.get("ledgerId"));
        result.put("sourceClassificationId",source==null?null:source.get("id"));
        result.put("sourceParts",source==null?List.of():base.parts("finance_open_item_classification_parts",(UUID)source.get("id")));
        var previous=base.latest("finance_receipt_classification_batches","receipt_line_id",lineId);
        result.put("revision",previous==null?-1:previous.get("revision"));
        result.put("parts",previous==null?List.of():base.parts("finance_receipt_classification_parts",(UUID)previous.get("id")));
        result.put("suggestion",base.singleCategory(source));ReportQueryKit.includeDecimalTexts(result);return result;
    }
    @Transactional
    public Result classifyReceipt(UUID lineId,ReceiptInput input){
        base.write("finance_receipt:approve");requireRequest(input==null?null:input.requestId());base.lock();
        var fact=receiptFact(lineId);var source=base.latest("finance_open_item_classification_batches","ledger_id",(UUID)fact.get("ledgerId"));
        var allowed=Set.of("GOODS","MATERIAL");
        if(input.parts()==null||input.parts().isEmpty()||input.parts().size()>2)throw invalid("请填写原收款行的货款/物料归属");
        var seen=new HashSet<String>();var values=new ArrayList<ReceiptPart>();
        for(var part:input.parts()){
            if(part==null||!allowed.contains(part.category())||!seen.add(part.category()))throw invalid("收款归属须对应来源，不能重复或混入其他类别");
            values.add(new ReceiptPart(part.category(),nonnegative(part.amountOriginal(),true),nonnegative(part.writeOffOriginal(),true),
                nonnegative(part.cashLocal(),false),nonnegative(part.writeOffLocal(),false),nonnegative(part.bookLocal(),false)));
        }
        values.sort(Comparator.comparing(ReceiptPart::category));
        String reference=reference(input.sourceReference()),fingerprint=base.fingerprint(List.of(lineId,input.expectedRevision(),input.sourceClassificationId(),reference,values));
        Result replay=base.replay("finance_receipt_classification_batches",input.requestId(),fingerprint);if(replay!=null)return replay;
        requireBatch(source,input.sourceClassificationId());requireAr(source,fact);
        if(!base.categorySet("finance_open_item_classification_parts",input.sourceClassificationId()).containsAll(seen))throw invalid("收款归属不属于当前来源");
        long revision=next(base.latest("finance_receipt_classification_batches","receipt_line_id",lineId),input.expectedRevision());
        equal(sum(values.stream().map(ReceiptPart::amountOriginal).toList()),amount(fact,"amountOriginal"),"收款原币归属");
        equal(sum(values.stream().map(ReceiptPart::writeOffOriginal).toList()),amount(fact,"writeOffOriginal"),"冲销原币归属");
        equal(sum(values.stream().map(ReceiptPart::cashLocal).toList()),amount(fact,"cashLocal"),"实际回款本币归属");
        equal(sum(values.stream().map(ReceiptPart::writeOffLocal).toList()),amount(fact,"writeOffLocal"),"冲销本币归属");
        equal(sum(values.stream().map(ReceiptPart::bookLocal).toList()),amount(fact,"bookLocal"),"账面核销归属");
        UUID id=base.batchId("AR_RECEIPT",lineId,input.requestId());
        db.update("""
            INSERT INTO finance_receipt_classification_batches(id,request_id,receipt_line_id,revision,source_classification_id,
              currency_id,amount_original,write_off_original,cash_local,write_off_local,book_local,source_reference,fingerprint,created_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,id,input.requestId(),lineId,revision,input.sourceClassificationId(),fact.get("currencyId"),fact.get("amountOriginal"),
                fact.get("writeOffOriginal"),fact.get("cashLocal"),fact.get("writeOffLocal"),fact.get("bookLocal"),reference,fingerprint,current.requireId());
        for(var part:values)db.update("INSERT INTO finance_receipt_classification_parts(batch_id,category,amount_original,write_off_original,cash_local,write_off_local,book_local) VALUES(?,?,?,?,?,?,?)",
            id,part.category(),part.amountOriginal(),part.writeOffOriginal(),part.cashLocal(),part.writeOffLocal(),part.bookLocal());
        if(base.correctionBatch("AR_RECEIPT",lineId,input.requestId())==null)requireCapacities(Set.of((UUID)fact.get("ledgerId")));return new Result(id,revision,"APPLIED");
    }

    @Transactional(readOnly=true)
    public Map<String,Object> offset(UUID id){
        base.read();var result=new LinkedHashMap<>(offsetFact(id));
        boolean prepay=ordinaryPrepayment(result);
        var source=prepay?null:base.latest("finance_open_item_classification_batches","ledger_id",(UUID)result.get("sourceLedgerId"));
        var target=base.latest("finance_open_item_classification_batches","ledger_id",(UUID)result.get("targetLedgerId"));
        result.put("sourceKind",prepay?"PREPAYMENT":"CREDIT");result.put("sourceClassificationId",source==null?null:source.get("id"));
        result.put("targetClassificationId",target==null?null:target.get("id"));
        result.put("sourceParts",prepay?List.of(Map.of("category","PREPAYMENT")):source==null?List.of():base.parts("finance_open_item_classification_parts",(UUID)source.get("id")));
        result.put("targetParts",target==null?List.of():base.parts("finance_open_item_classification_parts",(UUID)target.get("id")));
        var previous=base.latest("finance_customer_offset_classification_batches","offset_id",id);
        result.put("revision",previous==null?-1:previous.get("revision"));
        result.put("parts",previous==null?List.of():base.parts("finance_customer_offset_classification_parts",(UUID)previous.get("id")));
        ReportQueryKit.includeDecimalTexts(result);return result;
    }
    @Transactional
    public Result classifyOffset(UUID offsetId,CustomerOffsetInput input){
        base.write("finance_receipt:approve");requireRequest(input==null?null:input.requestId());base.lock();var fact=offsetFact(offsetId);
        boolean prepay=ordinaryPrepayment(fact);var target=base.latest("finance_open_item_classification_batches","ledger_id",(UUID)fact.get("targetLedgerId"));
        Set<String> sourceCategories;
        if(prepay){if(input.sourceClassificationId()!=null)throw invalid("预收应用保留真实预收来源，不伪造应收分类");sourceCategories=Set.of("PREPAYMENT");}
        else{sourceCategories=Set.of("GOODS","MATERIAL");}
        var targets=Set.of("GOODS","MATERIAL");
        if(input.parts()==null||input.parts().isEmpty()||input.parts().size()>4)throw invalid("请明确抵销两端逐类份额");
        var seen=new HashSet<String>();var values=new ArrayList<OffsetPart>();
        for(var part:input.parts()){
            if(part==null||!sourceCategories.contains(part.sourceCategory())||!targets.contains(part.targetCategory())||!seen.add(part.sourceCategory()+"/"+part.targetCategory()))throw invalid("抵销两端归属不符或重复");
            values.add(new OffsetPart(part.sourceCategory(),part.targetCategory(),nonnegative(part.amountOriginal(),true),nonnegative(part.sourceLocal(),false),nonnegative(part.targetLocal(),false)));
        }
        values.sort(Comparator.comparing(OffsetPart::sourceCategory).thenComparing(OffsetPart::targetCategory));
        String reference=reference(input.sourceReference());var body=new LinkedHashMap<String,Object>();body.put("id",offsetId);body.put("input",input);body.put("parts",values);
        String fingerprint=base.fingerprint(body);Result replay=base.replay("finance_customer_offset_classification_batches",input.requestId(),fingerprint);if(replay!=null)return replay;
        requireBatch(target,input.targetClassificationId());requireAr(target,fact);
        if(!prepay){var source=base.latest("finance_open_item_classification_batches","ledger_id",(UUID)fact.get("sourceLedgerId"));requireBatch(source,input.sourceClassificationId());requireAr(source,fact);}
        for(var p:values)if(!base.categorySet("finance_open_item_classification_parts",input.targetClassificationId()).contains(p.targetCategory())||!prepay&&!base.categorySet("finance_open_item_classification_parts",input.sourceClassificationId()).contains(p.sourceCategory()))throw invalid("抵销分类不属于当前两端来源");
        long revision=next(base.latest("finance_customer_offset_classification_batches","offset_id",offsetId),input.expectedRevision());
        equal(sum(values.stream().map(OffsetPart::amountOriginal).toList()),amount(fact,"amountOriginal"),"抵销原币归属");
        equal(sum(values.stream().map(OffsetPart::sourceLocal).toList()),amount(fact,"sourceLocal"),"抵销来源账面归属");
        equal(sum(values.stream().map(OffsetPart::targetLocal).toList()),amount(fact,"targetLocal"),"抵销目标账面归属");
        UUID id=base.batchId("AR_OFFSET",offsetId,input.requestId());db.update("""
            INSERT INTO finance_customer_offset_classification_batches(id,request_id,offset_id,revision,source_classification_id,
              target_classification_id,source_kind,amount_original,source_local,target_local,source_reference,fingerprint,created_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,id,input.requestId(),offsetId,revision,input.sourceClassificationId(),input.targetClassificationId(),prepay?"PREPAYMENT":"CREDIT",fact.get("amountOriginal"),fact.get("sourceLocal"),fact.get("targetLocal"),reference,fingerprint,current.requireId());
        for(var part:values)db.update("INSERT INTO finance_customer_offset_classification_parts(batch_id,source_category,target_category,amount_original,source_local,target_local) VALUES(?,?,?,?,?,?)",
            id,part.sourceCategory(),part.targetCategory(),part.amountOriginal(),part.sourceLocal(),part.targetLocal());
        var ledgers=new HashSet<UUID>();ledgers.add((UUID)fact.get("targetLedgerId"));if(!prepay)ledgers.add((UUID)fact.get("sourceLedgerId"));if(base.correctionBatch("AR_OFFSET",offsetId,input.requestId())==null)requireCapacities(ledgers);
        return new Result(id,revision,"APPLIED");
    }
    private void requireCapacities(Set<UUID> ledgers){for(UUID id:ledgers)if(Boolean.TRUE.equals(db.queryForObject("SELECT fn_finance_receivable_classification_exceeds(?)",Boolean.class,id)))throw invalid("某一日期的货款或物料清偿超过原币/账面份额，请核对完整关联归属");}
    private static boolean ordinaryPrepayment(Map<String,Object> fact){return "CUSTOMER_PREPAYMENT".equals(fact.get("sourceOpenItemKind"))&&fact.get("sourceLegacyImportId")==null;}
    private static void requireAr(Map<String,Object> batch,Map<String,Object> fact){if(!"AR".equals(batch.get("direction"))||!Objects.equals(batch.get("party_id"),fact.get("partyId"))||!Objects.equals(batch.get("currency_id"),fact.get("currencyId")))throw invalid("来源分类与原客户或实际币别不一致");}
    Map<String,Object> receiptFact(UUID id){
        var rows=db.queryForList("""
            SELECT line.id AS "receiptLineId",line.applied_ledger_id AS "ledgerId",receipt.client_id AS "partyId",
              receipt.bill_no AS "billNo",receipt.bill_date AS "billDate",receipt.status,receipt.reversed_at AS "reversedAt",receipt.currency_id AS "currencyId",
              line.amount_original AS "amountOriginal",line.write_off_amount AS "writeOffOriginal",
              line.amount_local AS "cashLocal",line.write_off_local AS "writeOffLocal",line.applied_amount_local AS "bookLocal",
              line.exchange_diff AS "exchangeDiff",receipt.account_currency_id AS "bankCurrencyId",receipt.account_amount AS "bankAmount"
            FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id
            WHERE line.id=? AND NOT line.is_deleted AND NOT receipt.is_deleted AND receipt.status IN(1,-1)
              AND receipt.receipt_kind='AR_SETTLEMENT' AND receipt.settlement_authority_version>0
              AND receipt.legacy_id IS NULL AND receipt.legacy_import_run_id IS NULL
            """,id);
        if(rows.size()!=1)throw missing("原已核收款行不存在");var result=rows.getFirst();for(String key:List.of("amountOriginal","writeOffOriginal","cashLocal","writeOffLocal","bookLocal"))amount(result,key);return result;
    }
    Map<String,Object> offsetFact(UUID id){
        var rows=db.queryForList("""
            SELECT actual.id AS "offsetId",actual.source_ledger_id AS "sourceLedgerId",actual.target_ledger_id AS "targetLedgerId",
              batch.client_id AS "partyId",actual.currency_id AS "currencyId",actual.status,actual.reversed_at AS "reversedAt",actual.effective_date AS "effectiveDate",
              actual.amount_original AS "amountOriginal",actual.source_amount_local AS "sourceLocal",actual.target_amount_local AS "targetLocal",
              source.open_item_kind AS "sourceOpenItemKind",source.legacy_import_run_id AS "sourceLegacyImportId"
            FROM customer_open_item_offsets actual JOIN customer_open_item_offset_batches batch ON batch.id=actual.offset_batch_id
            JOIN ar_ap_ledger source ON source.id=actual.source_ledger_id
            WHERE actual.id=? AND actual.status IN('APPLIED','REVERSED')
            """,id);
        if(rows.size()!=1)throw missing("原客户抵销记录不存在");return rows.getFirst();
    }
    private static ApiException invalid(String text){return new ApiException(ErrorCode.VALIDATION_FAILED,text);}
    private static ApiException missing(String text){return new ApiException(ErrorCode.NOT_FOUND,text);}
}
