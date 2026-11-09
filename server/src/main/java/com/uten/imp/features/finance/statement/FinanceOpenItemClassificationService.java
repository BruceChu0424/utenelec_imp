package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationContracts.*;

/** Classifies an existing open item and its real settlement rows without changing their financial facts. */
@Service @RequiredArgsConstructor
public class FinanceOpenItemClassificationService {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final FinanceDocumentAccessPolicy access;
    void read(){CurrentAuthorityGuard.requireAll("finance_report:view","ar_ap_ledger:view");FinanceCompanyReportAccess.require(access);}
    void write(String permission){read();CurrentAuthorityGuard.requireAll(permission);}
    void lock(){tx.bind();com.uten.imp.application.concurrency.FinanceClassificationLock.lock(db);}

    @Transactional(readOnly=true)
    public Map<String,Object> sources(String direction,UUID partyId,UUID currencyId,boolean pendingOnly,int page,int size) {
        read();if(direction==null||!Set.of("AR","AP").contains(direction))throw invalid("请选择应收或应付");
        int safePage=Math.max(1,page),safeSize=Math.max(1,Math.min(size,Pageables.MAX_PAGE_SIZE));
        var args=new ArrayList<Object>();args.add(direction);String where=" WHERE ledger.direction=? AND ledger.status IN(1,-1) AND(ledger.open_item_kind NOT IN('PREPAYMENT','CUSTOMER_PREPAYMENT') OR ledger.legacy_import_run_id IS NOT NULL)";
        if(partyId!=null){where+=" AND "+(direction.equals("AP")?"ledger.supplier_id":"ledger.client_id")+"=?";args.add(partyId);}
        if(currencyId!=null){where+=" AND ledger.currency_id=?";args.add(currencyId);}
        if(pendingOnly)where+=" AND classified.id IS NULL";
        String from=" FROM ar_ap_ledger ledger LEFT JOIN v_finance_open_item_classification_current classified ON classified.ledger_id=ledger.id LEFT JOIN suppliers supplier ON supplier.id=ledger.supplier_id LEFT JOIN clients client ON client.id=ledger.client_id LEFT JOIN currencies currency ON currency.id=ledger.currency_id";
        long total=Objects.requireNonNull(db.queryForObject("SELECT count(*)"+from+where,Long.class,args.toArray()));args.add(safeSize);args.add((long)(safePage-1)*safeSize);
        var items=db.queryForList("SELECT ledger.id AS \"ledgerId\",ledger.bill_no AS \"billNo\",ledger.source_doc_type AS \"sourceDocType\",ledger.bill_date AS \"billDate\",ledger.currency_id AS \"currencyId\",ledger.supplier_id AS \"supplierId\",ledger.client_id AS \"clientId\",CASE WHEN ledger.direction='AR' THEN client.code ELSE supplier.code END AS \"partyCode\",CASE WHEN ledger.direction='AR' THEN client.name ELSE supplier.name END AS \"partyName\",currency.code AS \"currencyCode\",classified.id AS \"classificationId\",classified.revision"+from+where+" ORDER BY ledger.bill_date DESC,ledger.bill_no,ledger.id LIMIT ? OFFSET ?",args.toArray());
        return Map.of("items",items,"page",safePage,"size",safeSize,"total",total,"totalPages",(total+safeSize-1)/safeSize);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> source(UUID ledgerId) {
        read();var source=sourceFact(ledgerId);var result=new LinkedHashMap<>(source);
        var batch=latest("finance_open_item_classification_batches","ledger_id",ledgerId);
        result.put("classificationId",batch==null?null:batch.get("id"));result.put("revision",batch==null?-1:batch.get("revision"));
        result.put("parts",batch==null?List.of():parts("finance_open_item_classification_parts",(UUID)batch.get("id")));
        boolean ar="AR".equals(source.get("direction"));
        var cash=referencesFor(ledgerId,ar,"cash",1,50);var offsets=referencesFor(ledgerId,ar,"offsets",1,50);
        result.put(ar?"receipts":"payments",cash.get("items"));result.put("offsets",offsets.get("items"));
        result.put("cashReferences",cash);result.put("offsetReferences",offsets);
        ReportQueryKit.includeDecimalTexts(result);return result;
    }

    @Transactional(readOnly=true)
    public Map<String,Object> references(UUID ledgerId,String kind,int page,int size){
        read();var source=sourceFact(ledgerId);return referencesFor(ledgerId,"AR".equals(source.get("direction")),kind,page,size);
    }
    private Map<String,Object> referencesFor(UUID ledgerId,boolean ar,String kind,int page,int size){
        int safePage=Math.max(1,page),safeSize=Math.max(1,Math.min(size,Pageables.MAX_PAGE_SIZE));String select,from,where,order;Object[] ids;
        if("cash".equals(kind)){
            String parent=ar?"receipt":"payment",table=ar?"receipts":"payments";
            select="SELECT line.id AS \""+parent+"LineId\",cash.bill_no AS \"billNo\",cash.bill_date AS \"billDate\",classified.id AS \"classificationId\",classified.revision";
            from=" FROM finance_"+parent+"_lines line JOIN finance_"+table+" cash ON cash.id=line."+parent+"_id LEFT JOIN v_finance_"+parent+"_classification_current classified ON classified."+parent+"_line_id=line.id";
            where=" WHERE line.applied_ledger_id=? AND NOT line.is_deleted AND cash.status IN(1,-1) AND NOT cash.is_deleted";
            order=" ORDER BY cash.bill_date,cash.bill_no,line.line_no,line.id";ids=new Object[]{ledgerId};
        }else if("offsets".equals(kind)){
            String party=ar?"customer":"supplier";
            select="SELECT offset_row.id AS \"offsetId\",offset_row.effective_date AS \"effectiveDate\",offset_row.source_ledger_id AS \"sourceLedgerId\",offset_row.target_ledger_id AS \"targetLedgerId\",classified.id AS \"classificationId\",classified.revision";
            from=" FROM "+party+"_open_item_offsets offset_row LEFT JOIN v_finance_"+party+"_offset_classification_current classified ON classified.offset_id=offset_row.id";
            where=" WHERE(offset_row.source_ledger_id=? OR offset_row.target_ledger_id=?) AND offset_row.status IN('APPLIED','REVERSED')";
            order=" ORDER BY offset_row.effective_date,offset_row.id";ids=new Object[]{ledgerId,ledgerId};
        }else throw invalid("请选择原收付款行或抵销记录");
        long total=Objects.requireNonNull(db.queryForObject("SELECT count(*)"+from+where,Long.class,ids));
        var args=new ArrayList<>(Arrays.asList(ids));args.add(safeSize);args.add((long)(safePage-1)*safeSize);
        var items=db.queryForList(select+from+where+order+" LIMIT ? OFFSET ?",args.toArray());
        items.forEach(ReportQueryKit::includeDecimalTexts);
        return Map.of("items",items,"page",safePage,"size",safeSize,"total",total,"totalPages",(total+safeSize-1)/safeSize);
    }

    @Transactional
    public Result classifySource(UUID ledgerId,SourceInput input) {
        read();requireRequest(input==null?null:input.requestId());lock();var source=sourceFact(ledgerId);
        write("AP".equals(source.get("direction"))?"supplier_settlement:confirm":"finance_receipt:approve");
        requireSourceVerified(source);String reference=reference(input.sourceReference());
        var values=sourceParts(input.parts(),source.get("direction").toString());
        LocalDate effective=date(source,"effectiveFrom");if(input.effectiveFrom()!=null&&!input.effectiveFrom().equals(effective))throw invalid("分类日期须保留来源单据或已证明期初的原日期");
        String fingerprint=fingerprint(List.of(ledgerId,input.expectedRevision(),effective,reference,values));
        Result replay=replay("finance_open_item_classification_batches",input.requestId(),fingerprint);if(replay!=null)return replay;
        var before=latest("finance_open_item_classification_batches","ledger_id",ledgerId);long revision=next(before,input.expectedRevision());
        if(correctionBatch("SOURCE",ledgerId,input.requestId())==null){
        if(before!=null&&Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM v_finance_classification_actual_references WHERE ledger_id=?)",Boolean.class,ledgerId)))throw conflict("已分类来源已被实际收付款、抵销或预付应用引用，请完整更正关联图，不能只改单一来源");
        if(Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM finance_supplier_advance_applications WHERE target_ledger_id=?)",Boolean.class,ledgerId)))throw conflict("该来源分类已被预付应用引用，不能独立改变；请先核对关联应用原分配");
        if(Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM finance_payment_classification_batches payment JOIN finance_open_item_classification_batches source ON source.id=payment.source_classification_id WHERE source.ledger_id=?) OR EXISTS(SELECT 1 FROM finance_supplier_offset_classification_batches offset_batch JOIN finance_open_item_classification_batches source ON source.id IN(offset_batch.source_classification_id,offset_batch.target_classification_id) WHERE source.ledger_id=?)",Boolean.class,ledgerId,ledgerId)))throw conflict("该来源分类已被付款或抵销分配引用，不能独立改变；请先受控更正关联分配");
        if(Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM finance_receipt_classification_batches receipt JOIN finance_open_item_classification_batches source ON source.id=receipt.source_classification_id WHERE source.ledger_id=?) OR EXISTS(SELECT 1 FROM finance_customer_offset_classification_batches offset_batch JOIN finance_open_item_classification_batches source ON source.id IN(offset_batch.source_classification_id,offset_batch.target_classification_id) WHERE source.ledger_id=?)",Boolean.class,ledgerId,ledgerId)))throw conflict("该来源分类已被收款或抵销分配引用，不能独立改变；请使用受控更正保留全部关联归属");
        }
        equal(sum(values.stream().map(Part::amountOriginal).toList()),amount(source,"amountOriginal"),"来源原币分配");equal(sum(values.stream().map(Part::amountLocal).toList()),amount(source,"amountLocal"),"来源本币分配");
        for(var part:values){sameSign(part.amountOriginal(),amount(source,"amountOriginal"));sameSign(part.amountLocal(),amount(source,"amountLocal"));}
        UUID id=batchId("SOURCE",ledgerId,input.requestId());db.update("INSERT INTO finance_open_item_classification_batches(id,request_id,ledger_id,revision,direction,party_id,currency_id,effective_from,amount_original,amount_local,source_reference,fingerprint,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                id,input.requestId(),ledgerId,revision,source.get("direction"),source.get("partyId"),source.get("currencyId"),effective,source.get("amountOriginal"),source.get("amountLocal"),reference,fingerprint,current.requireId());
        for(var part:values)db.update("INSERT INTO finance_open_item_classification_parts(batch_id,category,amount_original,amount_local) VALUES(?,?,?,?)",id,part.category(),part.amountOriginal(),part.amountLocal());
        return new Result(id,revision,"APPLIED");
    }

    @Transactional(readOnly=true)
    public Map<String,Object> payment(UUID lineId) {
        read();var fact=paymentFact(lineId);var result=new LinkedHashMap<>(fact);UUID ledger=(UUID)fact.get("ledgerId");var source=latest("finance_open_item_classification_batches","ledger_id",ledger);
        result.put("sourceClassificationId",source==null?null:source.get("id"));result.put("sourceParts",source==null?List.of():parts("finance_open_item_classification_parts",(UUID)source.get("id")));
        var batch=latest("finance_payment_classification_batches","payment_line_id",lineId);result.put("revision",batch==null?-1:batch.get("revision"));result.put("parts",batch==null?List.of():parts("finance_payment_classification_parts",(UUID)batch.get("id")));
        result.put("suggestion",singleCategory(source));ReportQueryKit.includeDecimalTexts(result);return result;
    }

    @Transactional
    public Result classifyPayment(UUID lineId,PaymentInput input) {
        write("finance_payment:approve");requireRequest(input==null?null:input.requestId());lock();var source=paymentFact(lineId);
        var values=paymentParts(input.parts(),Set.of("GOODS","MOULD"));
        String reference=reference(input.sourceReference()),fingerprint=fingerprint(List.of(lineId,input.expectedRevision(),input.sourceClassificationId(),reference,values));
        Result replay=replay("finance_payment_classification_batches",input.requestId(),fingerprint);if(replay!=null)return replay;
        requireBatch(latest("finance_open_item_classification_batches","ledger_id",(UUID)source.get("ledgerId")),input.sourceClassificationId());paymentParts(values,categorySet("finance_open_item_classification_parts",input.sourceClassificationId()));
        long revision=next(latest("finance_payment_classification_batches","payment_line_id",lineId),input.expectedRevision());
        equal(sum(values.stream().map(PaymentPart::amountOriginal).toList()),amount(source,"amountOriginal"),"付款原币分配");
        equal(sum(values.stream().map(PaymentPart::cashLocal).toList()),amount(source,"cashLocal"),"实际付款本币分配");
        equal(sum(values.stream().map(PaymentPart::bookLocal).toList()),amount(source,"bookLocal"),"账面核销本币分配");
        UUID id=batchId("AP_PAYMENT",lineId,input.requestId());db.update("INSERT INTO finance_payment_classification_batches(id,request_id,payment_line_id,revision,source_classification_id,currency_id,amount_original,cash_local,book_local,source_reference,fingerprint,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                id,input.requestId(),lineId,revision,input.sourceClassificationId(),source.get("currencyId"),source.get("amountOriginal"),source.get("cashLocal"),source.get("bookLocal"),reference,fingerprint,current.requireId());
        for(var part:values)db.update("INSERT INTO finance_payment_classification_parts(batch_id,category,amount_original,cash_local,book_local) VALUES(?,?,?,?,?)",id,part.category(),part.amountOriginal(),part.cashLocal(),part.bookLocal());
        if(correctionBatch("AP_PAYMENT",lineId,input.requestId())==null){requireCapacities(Set.of((UUID)source.get("ledgerId")));}return new Result(id,revision,"APPLIED");
    }

    @Transactional(readOnly=true)
    public Map<String,Object> offset(UUID offsetId) {
        read();var fact=offsetFact(offsetId);var result=new LinkedHashMap<>(fact);
        var source=latest("finance_open_item_classification_batches","ledger_id",(UUID)fact.get("sourceLedgerId"));var target=latest("finance_open_item_classification_batches","ledger_id",(UUID)fact.get("targetLedgerId"));
        result.put("sourceClassificationId",source==null?null:source.get("id"));result.put("targetClassificationId",target==null?null:target.get("id"));
        result.put("sourceParts",source==null?List.of():parts("finance_open_item_classification_parts",(UUID)source.get("id")));result.put("targetParts",target==null?List.of():parts("finance_open_item_classification_parts",(UUID)target.get("id")));
        var batch=latest("finance_supplier_offset_classification_batches","offset_id",offsetId);result.put("revision",batch==null?-1:batch.get("revision"));result.put("parts",batch==null?List.of():parts("finance_supplier_offset_classification_parts",(UUID)batch.get("id")));
        result.put("sourceSuggestion",singleCategory(source));result.put("targetSuggestion",singleCategory(target));ReportQueryKit.includeDecimalTexts(result);return result;
    }

    @Transactional
    public Result classifyOffset(UUID offsetId,OffsetInput input) {
        write("supplier_settlement:confirm");requireRequest(input==null?null:input.requestId());lock();var source=offsetFact(offsetId);
        var values=offsetParts(input.parts(),Set.of("GOODS","MOULD"),Set.of("GOODS","MOULD"));
        String reference=reference(input.sourceReference()),fingerprint=fingerprint(List.of(offsetId,input.expectedRevision(),input.sourceClassificationId(),input.targetClassificationId(),reference,values));
        Result replay=replay("finance_supplier_offset_classification_batches",input.requestId(),fingerprint);if(replay!=null)return replay;
        requireBatch(latest("finance_open_item_classification_batches","ledger_id",(UUID)source.get("sourceLedgerId")),input.sourceClassificationId());
        requireBatch(latest("finance_open_item_classification_batches","ledger_id",(UUID)source.get("targetLedgerId")),input.targetClassificationId());
        offsetParts(values,categorySet("finance_open_item_classification_parts",input.sourceClassificationId()),categorySet("finance_open_item_classification_parts",input.targetClassificationId()));
        long revision=next(latest("finance_supplier_offset_classification_batches","offset_id",offsetId),input.expectedRevision());
        equal(sum(values.stream().map(OffsetPart::amountOriginal).toList()),amount(source,"amountOriginal"),"抵销原币分配");equal(sum(values.stream().map(OffsetPart::sourceLocal).toList()),amount(source,"sourceLocal"),"贷项本币分配");equal(sum(values.stream().map(OffsetPart::targetLocal).toList()),amount(source,"targetLocal"),"应付本币分配");
        UUID id=batchId("AP_OFFSET",offsetId,input.requestId());db.update("INSERT INTO finance_supplier_offset_classification_batches(id,request_id,offset_id,revision,source_classification_id,target_classification_id,amount_original,source_local,target_local,source_reference,fingerprint,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                id,input.requestId(),offsetId,revision,input.sourceClassificationId(),input.targetClassificationId(),source.get("amountOriginal"),source.get("sourceLocal"),source.get("targetLocal"),reference,fingerprint,current.requireId());
        for(var part:values)db.update("INSERT INTO finance_supplier_offset_classification_parts(batch_id,source_category,target_category,amount_original,source_local,target_local) VALUES(?,?,?,?,?,?)",id,part.sourceCategory(),part.targetCategory(),part.amountOriginal(),part.sourceLocal(),part.targetLocal());
        if(correctionBatch("AP_OFFSET",offsetId,input.requestId())==null){requireCapacities(Set.of((UUID)source.get("sourceLedgerId"),(UUID)source.get("targetLedgerId")));}return new Result(id,revision,"APPLIED");
    }

    Map<String,Object> sourceFact(UUID id) {
        var values=db.queryForList("""
                SELECT ledger.id AS "ledgerId",ledger.direction,ledger.status,ledger.is_deleted AS "sourceDeleted",ledger.bill_no AS "billNo",ledger.source_doc_type AS "sourceDocType",ledger.source_doc_id AS "sourceDocId",
                    CASE WHEN ledger.direction='AP' THEN ledger.supplier_id ELSE ledger.client_id END AS "partyId",ledger.currency_id AS "currencyId",
                    CASE WHEN ledger.legacy_import_run_id IS NULL THEN ledger.amount_original ELSE (proof.initial_state->>'amount_balance_original')::numeric END AS "amountOriginal",
                    CASE WHEN ledger.legacy_import_run_id IS NULL THEN ledger.amount_original_local ELSE (proof.initial_state->>'amount_balance')::numeric END AS "amountLocal",
                    CASE WHEN ledger.legacy_import_run_id IS NULL THEN ledger.bill_date ELSE ((ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date END AS "effectiveFrom",
                    ledger.currency_id IS NOT NULL AND (ledger.legacy_id IS NULL OR ledger.legacy_import_run_id IS NOT NULL)
                        AND(ledger.open_item_kind NOT IN('PREPAYMENT','CUSTOMER_PREPAYMENT') OR ledger.legacy_import_run_id IS NOT NULL) AS "sourceVerified",
                    currency.code AS "currencyCode",currency.name AS "currencyName"
                FROM ar_ap_ledger ledger LEFT JOIN legacy_finance_import_sources proof ON proof.run_id=ledger.legacy_import_run_id AND proof.target_id=ledger.id AND proof.target_table='ar_ap_ledger'
                LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                WHERE ledger.id=? AND ledger.status IN(1,-1)
                """,id);
        if(values.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"往来项目不存在或尚未正式立账");return values.getFirst();
    }
    Map<String,Object> paymentFact(UUID id) {
        var values=db.queryForList("""
                SELECT line.id AS "paymentLineId",line.applied_ledger_id AS "ledgerId",payment.bill_no AS "billNo",payment.bill_date AS "billDate",
                       payment.status,payment.reversed_at AS "reversedAt",payment.currency_id AS "currencyId",line.amount_original AS "amountOriginal",line.amount_local AS "cashLocal",
                       COALESCE(line.applied_amount_local,CASE WHEN line.amount_local IS NOT NULL AND line.exchange_diff IS NOT NULL THEN line.amount_local-line.exchange_diff END) AS "bookLocal",
                       line.exchange_diff AS "exchangeDiff",payment.account_currency_id AS "bankCurrencyId",payment.account_amount AS "bankAmount",payment.bank_fee_local AS "bankFeeLocal",payment.amount_authority_version AS "authorityVersion",
                       COALESCE(line.applied_bill_no,ledger.bill_no) AS "appliedBillNo",currency.code AS "currencyCode",currency.name AS "currencyName"
                FROM finance_payment_lines line JOIN finance_payments payment ON payment.id=line.payment_id JOIN ar_ap_ledger ledger ON ledger.id=line.applied_ledger_id
                LEFT JOIN currencies currency ON currency.id=payment.currency_id
                WHERE line.id=? AND NOT line.is_deleted AND payment.status IN(1,-1) AND NOT payment.is_deleted
                  AND ledger.direction='AP' AND ledger.supplier_id=payment.supplier_id AND ledger.currency_id=payment.currency_id
                """,id);
        if(values.size()!=1)throw invalid("请选择已审核或已反审且具备明确应付项目、对象和币别的原付款行");var value=values.getFirst();
        if(((Number)value.get("authorityVersion")).intValue()<1)throw conflict("历史付款金额尚未经过服务端核验，不能通过分类把未知旧金额认作已确认事实");
        for(String key:List.of("amountOriginal","cashLocal","bookLocal")){if(value.get(key)==null)throw conflict("原付款现金或账面核销依据缺失，不能猜配");}return value;
    }
    Map<String,Object> offsetFact(UUID id) {
        var values=db.queryForList("SELECT off.id AS \"offsetId\",off.source_ledger_id AS \"sourceLedgerId\",off.target_ledger_id AS \"targetLedgerId\",off.supplier_id AS \"partyId\",off.currency_id AS \"currencyId\",off.status,off.reversed_at AS \"reversedAt\",off.effective_date AS \"effectiveDate\",off.amount_original AS \"amountOriginal\",off.source_amount_local AS \"sourceLocal\",off.target_amount_local AS \"targetLocal\",source.bill_no AS \"sourceBillNo\",target.bill_no AS \"targetBillNo\",currency.code AS \"currencyCode\",currency.name AS \"currencyName\" FROM supplier_open_item_offsets off JOIN ar_ap_ledger source ON source.id=off.source_ledger_id JOIN ar_ap_ledger target ON target.id=off.target_ledger_id LEFT JOIN currencies currency ON currency.id=off.currency_id WHERE off.id=? AND off.status IN('APPLIED','REVERSED')",id);
        if(values.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"原往来抵销记录不存在");return values.getFirst();
    }
    Map<String,Object> latest(String table,String key,UUID id){var values=db.queryForList("SELECT * FROM "+table+" WHERE "+key+"=? ORDER BY revision DESC LIMIT 1",id);return values.isEmpty()?null:values.getFirst();}
    List<Map<String,Object>> parts(String table,UUID id){var values=db.queryForList("SELECT * FROM "+table+" WHERE batch_id=? ORDER BY "+(table.contains("offset")?"source_category,target_category":"category"),id);values.forEach(ReportQueryKit::includeDecimalTexts);return values;}
    Set<String> categorySet(String table,UUID id){return new HashSet<>(db.queryForList("SELECT category FROM "+table+" WHERE batch_id=?",String.class,id));}
    String singleCategory(Map<String,Object> batch){if(batch==null)return null;var categories=categorySet("finance_open_item_classification_parts",(UUID)batch.get("id"));return categories.size()==1?categories.iterator().next():null;}
    Result replay(String table,UUID request,String fingerprint){var values=db.queryForList("SELECT id,revision,fingerprint,created_by FROM "+table+" WHERE request_id=?",request);if(values.isEmpty())return null;var value=values.getFirst();if(!Objects.equals(current.requireId(),value.get("created_by")))throw conflict("该请求属于另一操作人，请核对本人原请求");if(!fingerprint.equals(value.get("fingerprint")))throw conflict("原请求编号已提交不同内容，请核对原结果");return new Result((UUID)value.get("id"),((Number)value.get("revision")).longValue(),"APPLIED");}
    static long next(Map<String,Object> old,long expected){long revision=old==null?-1:((Number)old.get("revision")).longValue();if(expected!=revision)throw conflict("分类版本已变化，请刷新后核对");return Math.addExact(revision,1);}
    static void requireBatch(Map<String,Object> batch,UUID id){if(batch==null||id==null||!id.equals(batch.get("id")))throw conflict("请先完成来源往来项目的当前分类，并刷新分配依据");}
    static void requireSourceVerified(Map<String,Object> source){if(!Boolean.TRUE.equals(source.get("sourceVerified"))||source.get("amountOriginal")==null||source.get("amountLocal")==null||source.get("effectiveFrom")==null||source.get("partyId")==null)throw conflict("原往来项目的原币、本币、对象或历史期初日期尚未完整核验");}
    static void requireRequest(UUID id){if(id==null)throw invalid("请保留本次分类请求编号");}
    static String reference(String value){if(value==null||value.isBlank()||value.length()>2000)throw invalid("请填写不超过2000字的明确来源依据");return value.strip();}
    static BigDecimal amount(Map<String,Object> source,String key){Object value=source.get(key);if(value==null)throw conflict("来源金额尚未核验："+key);return new BigDecimal(value.toString());}
    static LocalDate date(Map<String,Object> value,String key){Object date=value.get(key);return date instanceof java.sql.Date sql?sql.toLocalDate():LocalDate.parse(date.toString());}
    static BigDecimal sum(List<BigDecimal> values){return values.stream().reduce(BigDecimal.ZERO,BigDecimal::add);}
    static void equal(BigDecimal assigned,BigDecimal original,String label){if(assigned.compareTo(original)!=0)throw invalid(label+"必须与原事实完整相等，不自动补差或舍入");}
    private static void sameSign(BigDecimal part,BigDecimal source){if(part.signum()!=0&&part.signum()!=source.signum())throw invalid("分类份额须与同一来源金额同向，不能用正负抵销凑总额");}
    static BigDecimal original(BigDecimal value){return FinancialExactAmount.require(value,"原币份额");}
    static BigDecimal book(BigDecimal value){return FinancialExactAmount.book(value,"本币份额");}
    static BigDecimal nonnegative(BigDecimal value,boolean original){var checked=original?original(value):book(value);if(checked.signum()<0)throw invalid("结算分配份额不能为负；反审按原记录反向事件体现");return checked;}
    private static List<Part> sourceParts(List<Part> input,String direction){if(input==null||input.isEmpty()||input.size()>2)throw invalid("请选择一至两种原分类");var result=new ArrayList<Part>();var seen=new HashSet<String>();Set<String> allowed="AP".equals(direction)?Set.of("GOODS","MOULD"):Set.of("GOODS","MATERIAL");for(var part:input){if(part==null||part.category()==null||!allowed.contains(part.category())||!seen.add(part.category()))throw invalid("分类不符或重复");result.add(new Part(part.category(),original(part.amountOriginal()),book(part.amountLocal())));}result.sort(Comparator.comparing(Part::category));return List.copyOf(result);}
    private static List<PaymentPart> paymentParts(List<PaymentPart> input,Set<String> allowed){if(input==null||input.isEmpty()||input.size()>2)throw invalid("请填写付款行分类份额");var result=new ArrayList<PaymentPart>();var seen=new HashSet<String>();for(var part:input){if(part==null||!allowed.contains(part.category())||!seen.add(part.category()))throw invalid("付款分类须对应来源，不能重复或混入未知类别");result.add(new PaymentPart(part.category(),nonnegative(part.amountOriginal(),true),nonnegative(part.cashLocal(),false),nonnegative(part.bookLocal(),false)));}result.sort(Comparator.comparing(PaymentPart::category));return List.copyOf(result);}
    private static List<OffsetPart> offsetParts(List<OffsetPart> input,Set<String> sources,Set<String> targets){if(input==null||input.isEmpty()||input.size()>4)throw invalid("请填写抵销两端明确分类份额");var result=new ArrayList<OffsetPart>();var seen=new HashSet<String>();for(var part:input){if(part==null||!sources.contains(part.sourceCategory())||!targets.contains(part.targetCategory())||!seen.add(part.sourceCategory()+"/"+part.targetCategory()))throw invalid("抵销分类须对应两端来源且不能重复");result.add(new OffsetPart(part.sourceCategory(),part.targetCategory(),nonnegative(part.amountOriginal(),true),nonnegative(part.sourceLocal(),false),nonnegative(part.targetLocal(),false)));}result.sort(Comparator.comparing(OffsetPart::sourceCategory).thenComparing(OffsetPart::targetCategory));return List.copyOf(result);}
    UUID correctionBatch(String kind,UUID objectId,UUID requestId){
        var rows=db.queryForList("""
            SELECT n.new_batch_id FROM finance_classification_correction_nodes n
            JOIN finance_classification_corrections c ON c.id=n.correction_id
            WHERE n.kind=? AND n.object_id=? AND n.new_batch_id=? AND c.status='BUILDING'
              AND c.created_tx=pg_current_xact_id() AND c.created_by=?
            """,kind,objectId,requestId,current.requireId());
        return rows.isEmpty()?null:(UUID)rows.getFirst().get("new_batch_id");
    }
    UUID batchId(String kind,UUID objectId,UUID requestId){UUID registered=correctionBatch(kind,objectId,requestId);return registered==null?UUID.randomUUID():registered;}
    String fingerprint(Object value){try{return ImmutableDocumentStore.digest(json.writeValueAsBytes(value));}catch(Exception ex){throw new IllegalStateException("分类请求校验失败",ex);}}
    void requireCapacities(Set<UUID> ledgerIds){
        for(UUID ledger:ledgerIds){var excess=db.queryForList(FinanceClassificationCapacitySql.SQL,ledger,ledger);if(!excess.isEmpty())throw invalid("分类结算在某一历史日期超过该货款/模具款原币或账面本币份额，请核对付款及抵销的实际归属");}
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
