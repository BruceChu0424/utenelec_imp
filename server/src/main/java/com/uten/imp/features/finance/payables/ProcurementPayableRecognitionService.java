package com.uten.imp.features.finance.payables;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.FinanceCompanyReportAccess;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.gl.FinanceControlledJournalService;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;

/** The native approval owns stock; this workflow alone converts its pending obligation into payable AP. */
@Service @RequiredArgsConstructor
public class ProcurementPayableRecognitionService implements ProcurementPayableRecognitionPort {
    private final JdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final FinancialAuxiliaryValidationPort auxiliaries;
    private final FinancialChartCurrencyReadPort currencies;
    private final FinanceControlledJournalService journals;
    private final ObjectProvider<ArApLedgerService> ledgers;
    private final SupplierClosedPeriodGuard closed;
    private final FinanceDocumentAccessPolicy access;
    private final ImmutableDocumentStore documents;
    @org.springframework.beans.factory.annotation.Autowired private NativeFinancialPostingAccountPort nativeAccounts;
    private static final String POLICY_LOCK="uten:procurement-first-payable-policy";
    private static final Object APPROVAL_CONTEXT=new Object();
    private record Decision(boolean enabled,LocalDate effectiveFrom,long policyVersion) {
        boolean deferred(LocalDate actualApprovalDay){return enabled&&effectiveFrom!=null&&!actualApprovalDay.isBefore(effectiveFrom);}
    }
    private record Account(UUID style,String code,UUID currency,FinancialAuxiliaryValidationPort.Ref auxiliary) { }
    public record PolicyInput(long expectedRevision,boolean enabled,LocalDate effectiveFrom,String sourceReference) { }
    public record Selected(UUID candidateId,String sourceFingerprint) { }
    public record Submission(UUID requestId,UUID supplierId,UUID currencyId,LocalDate effectiveDate,
            String sourceReference,String counterpartConfirmedBy,LocalDate counterpartConfirmedDate,List<Selected> candidates) { }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public boolean beginApproval(Source source) {
        if(source==null||source.id()==null||!Set.of("PURCHASE_RECEIPT","SUBCONTRACT_RECEIPT","PURCHASE_RETURN","SUBCONTRACT_RETURN","PURCHASE_IQC_CREDIT","SUBCONTRACT_IQC_CREDIT").contains(source.type()))throw invalid("缺少原生收退货来源身份");
        policyLock(false);
        @SuppressWarnings("unchecked") Map<Source,Decision> contexts=(Map<Source,Decision>)TransactionSynchronizationManager.getResource(APPROVAL_CONTEXT);
        if(contexts==null){
            contexts=new HashMap<>();TransactionSynchronizationManager.bindResource(APPROVAL_CONTEXT,contexts);
            final Map<Source,Decision> captured=contexts;
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization(){
                @Override public void suspend(){TransactionSynchronizationManager.unbindResourceIfPossible(APPROVAL_CONTEXT);}
                @Override public void resume(){TransactionSynchronizationManager.bindResource(APPROVAL_CONTEXT,captured);}
                @Override public void afterCompletion(int status){TransactionSynchronizationManager.unbindResourceIfPossible(APPROVAL_CONTEXT);}
            });
        }
        var existing=contexts.get(source);if(existing!=null)return existing.deferred(BusinessTime.today());
        var row=db.queryForMap("SELECT enabled,effective_from,row_version FROM finance_procurement_ap_policy WHERE singleton");
        var decision=new Decision(Boolean.TRUE.equals(row.get("enabled")),date(row.get("effective_from")),((Number)row.get("row_version")).longValue());
        contexts.put(source,decision);return decision.deferred(BusinessTime.today());
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public boolean defer(Candidate candidate) {
        @SuppressWarnings("unchecked") Map<Source,Decision> contexts=(Map<Source,Decision>)TransactionSynchronizationManager.getResource(APPROVAL_CONTEXT);
        Decision decision=contexts==null?null:contexts.get(candidate.source());
        if(decision==null)throw conflict("收退货审核未取得首次应付政策快照，本次没有立账");
        LocalDate approvedOn=BusinessTime.today();
        if(!decision.deferred(approvedOn))return false;
        tx.bind();UUID actor=current.requireId();
        FinancialExactAmount.require(candidate.amountOriginal(),"暂估原币");FinancialExactAmount.book(candidate.amountLocal(),"暂估本币");
        closed.requireOpen(candidate.supplierId(),candidate.currencyId(),approvedOn,"收退货暂估入账");
        if(count("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_type=? AND source_doc_id=? AND status=1 AND NOT is_deleted",candidate.source().type(),candidate.source().id())!=0)throw conflict("这个来源已有正式应付，不能重新改成待确认");
        boolean receipt=candidate.source().type().endsWith("_RECEIPT");
        Account pending=account(receipt?"PROCUREMENT_GRNI_PENDING":"PROCUREMENT_RETURN_PENDING_ASSET",candidate.supplierId(),candidate.currencyId(),approvedOn);UUID inventory=role("INVENTORY_ASSET");
        String snapshot=encode(candidate),fingerprint=hash(snapshot);UUID id=UUID.randomUUID();
        db.update("INSERT INTO finance_procurement_payable_routes(source_type,source_id,policy_version,approved_on,created_by)VALUES(?,?,?,?,?)",candidate.source().type(),candidate.source().id(),decision.policyVersion(),approvedOn,actor);
        UUID voucher=null;
        if(candidate.amountLocal().signum()!=0){
            BigDecimal local=candidate.amountLocal().abs(),original=candidate.amountOriginal().abs();
            var allocation=allocation(pending,candidate.currencyId(),original,candidate.exchangeRate(),id,snapshot);
            var entries=receipt?List.of(new FinanceControlledJournalService.Entry(inventory,1,local,"收货暂估存货"),new FinanceControlledJournalService.Entry(pending.style(),-1,local,"待对账确认暂估债务",allocation)):
                    List.of(new FinanceControlledJournalService.Entry(pending.style(),1,local,"待确认供应商退货贷项",allocation),new FinanceControlledJournalService.Entry(inventory,-1,local,"退货商业价；实际成本差额仍由原成本链处理"));
            voucher=journals.post(candidate.billNo()+"-暂估",approvedOn,"PROCUREMENT_PENDING",id,"PROCUREMENT_PAYABLE_CANDIDATE","原生审核后暂估；尚无正式应付",entries,actor).voucherId();
        }
        db.update("""
            INSERT INTO finance_procurement_payable_candidates(id,source_type,source_id,bill_no,commercial_date,accrual_date,due_date,
              supplier_id,currency_id,exchange_rate,amount_original,amount_local,settlement_method_id,settlement_style_legacy,
              inventory_style_id,pending_style_id,pending_account_code,pending_accounting_currency_id,auxiliary_id,auxiliary_snapshot,
              source_fingerprint,source_snapshot,pending_voucher_id,status,created_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?,?::jsonb,?,'PENDING',?)
            """,id,candidate.source().type(),candidate.source().id(),candidate.billNo(),candidate.commercialDate(),approvedOn,candidate.dueDate(),
                candidate.supplierId(),candidate.currencyId(),candidate.exchangeRate(),candidate.amountOriginal(),candidate.amountLocal(),candidate.settlementMethodId(),candidate.settlementStyleLegacy(),
                inventory,pending.style(),pending.code(),pending.currency(),pending.auxiliary().auxiliaryId(),encode(pending.auxiliary()),fingerprint,snapshot,voucher,actor);
        return true;
    }

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true,noRollbackFor=ApiException.class)
    public boolean requireReversible(Source source){
        var rows=db.queryForList("SELECT status FROM finance_procurement_payable_candidates WHERE source_type=? AND source_id=?",source.type(),source.id());
        if(rows.isEmpty())return false;
        if(!"PENDING".equals(rows.getFirst().get("status")))throw conflict("该来源已经财务对账确认，请先撤回下游付款/抵销，再反审对账确认，最后反审原收退货");
        return true;
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void sourceReversed(Source source){
        var rows=db.queryForList("SELECT * FROM finance_procurement_payable_candidates WHERE source_type=? AND source_id=? FOR UPDATE",source.type(),source.id());
        if(rows.isEmpty())return;requireReversible(source);var row=rows.getFirst();UUID reverse=null;
        if(row.get("pending_voucher_id")!=null)reverse=journals.reverse((UUID)row.get("pending_voucher_id"),row.get("bill_no")+"-暂估红冲",BusinessTime.today(),"PROCUREMENT_PENDING_REV",(UUID)row.get("id"),"PROCUREMENT_PAYABLE_CANDIDATE","原收退货已真实反审",current.requireId()).voucherId();
        db.update("UPDATE finance_procurement_payable_candidates SET status='SOURCE_REVERSED',source_reversed_at=now(),pending_reversal_voucher_id=? WHERE id=?",reverse,row.get("id"));
    }

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public UUID pendingSource(String receiptType,UUID receiptId){
        var rows=db.queryForList("SELECT id FROM finance_procurement_payable_candidates WHERE source_type=? AND source_id=? AND status<>'SOURCE_REVERSED'",receiptType+"_RECEIPT",receiptId);
        return rows.isEmpty()?null:(UUID)rows.getFirst().get("id");
    }

    @Transactional(readOnly=true) public Map<String,Object> policy(){read();return db.queryForMap("SELECT enabled,effective_from AS \"effectiveFrom\",source_reference AS \"sourceReference\",row_version AS revision FROM finance_procurement_ap_policy WHERE singleton");}
    @Transactional public Map<String,Object> configure(PolicyInput command){
        write();CurrentAuthorityGuard.requireAll("payment_style:edit");tx.bind();policyLock(true);
        if(command==null)throw invalid("请填写生效政策");reference(command.sourceReference());
        var before=db.queryForMap("SELECT * FROM finance_procurement_ap_policy WHERE singleton FOR UPDATE");
        if(((Number)before.get("row_version")).longValue()==command.expectedRevision()+1
                &&Boolean.valueOf(command.enabled()).equals(before.get("enabled"))&&Objects.equals(command.effectiveFrom(),date(before.get("effective_from")))
                &&Objects.equals(command.sourceReference(),before.get("source_reference"))&&current.requireId().equals(before.get("updated_by")))return policy();
        if(command.enabled()){
            if(command.sourceReference().trim().length()<8)throw invalid("启用依据至少填写8个字，保留实际变更来源");
            if(command.effectiveFrom()==null||command.effectiveFrom().isBefore(BusinessTime.today()))throw invalid("首次启用日期只能为今天或以后；历史正式来源保持原路线");
            for(String role:List.of("INVENTORY_ASSET","PROCUREMENT_GRNI_PENDING","PROCUREMENT_RETURN_PENDING_ASSET","AP_CONTROL"))role(role);
            for(String role:List.of("PROCUREMENT_GRNI_PENDING","PROCUREMENT_RETURN_PENDING_ASSET","AP_CONTROL")){
                UUID style=role(role);if(count("SELECT count(*) FROM finance_chart_code_styles WHERE style_id=?",style)!=1)throw conflict("请先将用途对应到唯一财务科目："+role);
                String code=db.queryForObject("SELECT code FROM finance_chart_code_styles WHERE style_id=?",String.class,style);
                var currency=currencies.read(Set.of(code)).get(code);if(currency==null||currency.currencyId()==null)throw conflict("请先维护会计币别："+code);
                if(count("SELECT count(*) FROM finance_account_auxiliary_rules WHERE account_code=? AND required AND 'SUPPLIER'=ANY(allowed_roles)",code)!=1)throw conflict("暂估债务、待确认退货资产和应付必须启用供应商辅助核算："+code);
            }
        }
        if(db.update("UPDATE finance_procurement_ap_policy SET enabled=?,effective_from=?,source_reference=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE singleton AND row_version=?",command.enabled(),command.effectiveFrom(),command.sourceReference(),current.requireId(),command.expectedRevision())!=1)throw conflict("政策已变化，请刷新后核对");return policy();
    }

    @Transactional(readOnly=true) public Map<String,Object> candidates(UUID supplierId,UUID currencyId,String status,int page,int size){
        read();int p=Math.max(1,page),s=Math.max(1,Math.min(100,size));var args=new ArrayList<Object>();String where=" WHERE true";
        if(supplierId!=null){where+=" AND c.supplier_id=?";args.add(supplierId);}if(currencyId!=null){where+=" AND c.currency_id=?";args.add(currencyId);}
        if(status!=null&&!status.isBlank()){if(!Set.of("PENDING","CONFIRMED","ZERO_CONFIRMED","SOURCE_REVERSED").contains(status))throw invalid("状态不正确");where+=" AND c.status=?";args.add(status);}
        long total=db.queryForObject("SELECT count(*) FROM finance_procurement_payable_candidates c"+where,Long.class,args.toArray());args.add(s);args.add((long)(p-1)*s);
        var rows=db.queryForList("SELECT c.id,c.source_type AS \"sourceType\",c.source_id AS \"sourceId\",c.bill_no AS \"billNo\",c.commercial_date AS \"commercialDate\",c.accrual_date AS \"accrualDate\",c.supplier_id AS \"supplierId\",supplier.name AS \"supplierName\",c.currency_id AS \"currencyId\",currency.name AS \"currencyName\",c.amount_original AS \"amountOriginal\",c.amount_local AS \"amountLocal\",c.source_fingerprint AS \"sourceFingerprint\",c.status,c.ledger_id AS \"ledgerId\",c.recognition_id AS \"recognitionId\" FROM finance_procurement_payable_candidates c LEFT JOIN suppliers supplier ON supplier.id=c.supplier_id LEFT JOIN currencies currency ON currency.id=c.currency_id"+where+" ORDER BY c.commercial_date,c.bill_no,c.id LIMIT ? OFFSET ?",args.toArray());
        rows.forEach(com.uten.imp.common.report.ReportQueryKit::includeDecimalTexts);return Map.of("items",rows,"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }

    @Transactional public Map<String,Object> submit(Submission command,String filename,String contentType,byte[] bytes){
        write();if(command==null||command.requestId()==null||command.supplierId()==null||command.currencyId()==null||command.candidates()==null||command.candidates().isEmpty()||command.candidates().size()>500)throw invalid("请选择同一供应商、同一真实币别的1至500个原来源");
        reference(command.sourceReference());reference(command.counterpartConfirmedBy());
        if(command.effectiveDate()==null||command.effectiveDate().isAfter(BusinessTime.today())||command.counterpartConfirmedDate()==null||command.counterpartConfirmedDate().isAfter(command.effectiveDate()))throw invalid("请填写实际已发生的对账和会计确认日期");
        if(filename==null||filename.isBlank()||filename.length()>240||filename.chars().anyMatch(Character::isISOControl)||bytes==null||bytes.length==0)throw invalid("请上传实际对账确认件并保留原文件名");
        tx.bind();policyLock(false);requestLock(command.requestId());String fileHash=ImmutableDocumentStore.digest(bytes),payload=hash(encode(command)+"|"+filename+"|"+contentType+"|"+fileHash);
        var old=db.queryForList("SELECT id,payload_hash,submitted_by FROM finance_procurement_ap_recognitions WHERE request_id=?",command.requestId());
        if(!old.isEmpty()){if(!Objects.equals(current.requireId(),old.getFirst().get("submitted_by")))throw conflict("原请求属于另一提交人，请保留本人原请求核对");if(!payload.equals(old.getFirst().get("payload_hash")))throw conflict("同一请求已有不同对账内容，不能覆盖");return recognition((UUID)old.getFirst().get("id"));}
        closed.requireOpen(command.supplierId(),command.currencyId(),command.effectiveDate(),"首次应付对账提交");
        var selected=selectCandidates(command);var document=documents.save("FINANCE_PROCUREMENT_AP_CONFIRMATION",filename,contentType,bytes);UUID id=UUID.randomUUID();
        db.update("""
            INSERT INTO finance_procurement_ap_recognitions(id,request_id,payload_hash,supplier_id,currency_id,effective_date,
              source_reference,counterpart_confirmed_by,counterpart_confirmed_date,file_provider,file_key,file_version,file_size,file_sha256,file_name,file_content_type,submitted_by,status)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'DRAFT')
            """,id,command.requestId(),payload,command.supplierId(),command.currencyId(),command.effectiveDate(),command.sourceReference(),command.counterpartConfirmedBy(),command.counterpartConfirmedDate(),
                document.provider(),document.key(),document.version(),document.size(),document.sha256(),filename,contentType,current.requireId());
        for(var row:selected)db.update("INSERT INTO finance_procurement_ap_recognition_lines(recognition_id,candidate_id,confirmed_original,confirmed_local,source_fingerprint)VALUES(?,?,?,?,?)",id,row.get("id"),row.get("amount_original"),row.get("amount_local"),row.get("source_fingerprint"));
        return recognition(id);
    }

    @Transactional public Map<String,Object> approve(UUID id){
        write();tx.bind();policyLock(false);var batch=batch(id,true);
        if("POSTED".equals(batch.get("status")))return recognition(id);
        if(!"DRAFT".equals(batch.get("status")))throw conflict("该对账确认已反审，请保留原记录并重新提交");
        if(current.requireId().equals(batch.get("submitted_by")))throw forbidden("对账提交人与内部审核人须为不同人员");
        closed.requireOpen((UUID)batch.get("supplier_id"),(UUID)batch.get("currency_id"),date(batch.get("effective_date")),"首次应付财务确认");
        var lines=db.queryForList("SELECT c.*,l.source_fingerprint AS reviewed_fingerprint FROM finance_procurement_ap_recognition_lines l JOIN finance_procurement_payable_candidates c ON c.id=l.candidate_id WHERE l.recognition_id=? ORDER BY c.id FOR UPDATE OF c",id);
        if(lines.isEmpty())throw conflict("对账没有真实来源");
        for(var row:lines){
            requirePending(row,batch.get("supplier_id"),batch.get("currency_id"),date(batch.get("effective_date")),row.get("reviewed_fingerprint"));
            UUID voucher=null,ledger=null;BigDecimal local=decimal(row,"amount_local"),original=decimal(row,"amount_original");
            if(original.signum()!=0){
                Account ap=account("AP_CONTROL",(UUID)row.get("supplier_id"),(UUID)row.get("currency_id"),date(batch.get("effective_date")));Account pending=new Account((UUID)row.get("pending_style_id"),row.get("pending_account_code").toString(),(UUID)row.get("pending_accounting_currency_id"),ref(row));boolean receipt=original.signum()>0;
                var req=new ArApLedgerService.ArApPostingRequest("AP",row.get("source_type").toString(),(UUID)row.get("source_id"),row.get("bill_no").toString(),date(batch.get("effective_date")),null,(UUID)row.get("supplier_id"),(UUID)row.get("currency_id"),decimal(row,"exchange_rate"),local,legacy(row.get("source_type").toString()),"对账确认："+id,original,date(row.get("due_date")),row.get("settlement_style_legacy")==null?null:((Number)row.get("settlement_style_legacy")).shortValue(),List.of(),(UUID)row.get("settlement_method_id"));
                String postingNo="APC-"+UUID.nameUUIDFromBytes((id+"|"+row.get("id")).getBytes(java.nio.charset.StandardCharsets.UTF_8));
                ledgers.getObject().postReconciledArAp(req,postingNo);
                ledger=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type=? AND source_doc_id=? AND status=1 AND NOT is_deleted",UUID.class,row.get("source_type"),row.get("source_id"));
                if(local.signum()!=0){
                var pendingAllocation=allocation(pending,(UUID)row.get("currency_id"),original.abs(),decimal(row,"exchange_rate"),(UUID)row.get("id"),row.get("source_snapshot").toString());
                var apAllocation=allocation(ap,(UUID)row.get("currency_id"),original.abs(),decimal(row,"exchange_rate"),ledger,encode(Map.of("recognitionId",id,"candidateId",row.get("id"))));
                voucher=journals.post(row.get("bill_no")+"-对账确认-"+ledger,date(batch.get("effective_date")),"PROCUREMENT_AP_RECOGNITION",ledger,"PROCUREMENT_AP_RECOGNITION_LINE","仅转正式应付；不重复采购成本",List.of(
                    new FinanceControlledJournalService.Entry(pending.style(),receipt?1:-1,local.abs(),"冲回原待确认余额",pendingAllocation),
                    new FinanceControlledJournalService.Entry(ap.style(),receipt?-1:1,local.abs(),"首次正式应付",apAllocation)),current.requireId()).voucherId();
                nativeAccounts.bindArApEntry(ledger,voucher,2,true);
                }
            }
            db.update("UPDATE finance_procurement_payable_candidates SET status=?,ledger_id=?,recognition_id=? WHERE id=?",original.signum()==0?"ZERO_CONFIRMED":"CONFIRMED",ledger,id,row.get("id"));
            db.update("UPDATE finance_procurement_ap_recognition_lines SET ledger_id=?,voucher_id=? WHERE recognition_id=? AND candidate_id=?",ledger,voucher,id,row.get("id"));
        }
        db.update("UPDATE finance_procurement_ap_recognitions SET status='POSTED',approved_by=?,approved_at=now() WHERE id=?",current.requireId(),id);return recognition(id);
    }

    @Transactional public Map<String,Object> reverse(UUID id,String reason){
        write();reference(reason);tx.bind();policyLock(false);var batch=batch(id,true);if("REVERSED".equals(batch.get("status")))return recognition(id);if(!"POSTED".equals(batch.get("status")))throw conflict("只能反审已入账的对账确认");
        closed.requireOpen((UUID)batch.get("supplier_id"),(UUID)batch.get("currency_id"),BusinessTime.today(),"首次应付对账反审");
        var rows=db.queryForList("SELECT c.*,l.voucher_id FROM finance_procurement_ap_recognition_lines l JOIN finance_procurement_payable_candidates c ON c.id=l.candidate_id WHERE l.recognition_id=? ORDER BY c.id FOR UPDATE OF c",id);
        for(var row:rows){if(!id.equals(row.get("recognition_id"))||!Set.of("CONFIRMED","ZERO_CONFIRMED").contains(row.get("status")))throw conflict("来源已转入其他对账记录，不能重复撤回");if(row.get("ledger_id")!=null){
            if(count("SELECT count(*) FROM procurement_iqc_credit_documents document WHERE document.source_ap_ledger_id=? AND EXISTS(SELECT 1 FROM procurement_iqc_credit_slices slice WHERE slice.credit_document_id=document.id AND fn_procurement_consideration_active('CREDIT',slice.id))",row.get("ledger_id"))>0)
                throw conflict("该正式应付已有实际IQC贷项账面分配，请先按原贷项记录撤回实际供应商贷项");
            ledgers.getObject().requireReversibleSource((UUID)row.get("source_id"),row.get("source_type").toString());}}
        for(var row:rows){UUID reversal=null;
            if(row.get("ledger_id")!=null){ledgers.getObject().reverseArAp((UUID)row.get("source_id"),row.get("source_type").toString());em.flush();if(row.get("voucher_id")!=null)reversal=journals.reverse((UUID)row.get("voucher_id"),row.get("bill_no")+"-对账反审-"+row.get("ledger_id"),BusinessTime.today(),"PROCUREMENT_AP_RECOGNITION_REV",(UUID)row.get("ledger_id"),"PROCUREMENT_AP_RECOGNITION_LINE",reason,current.requireId()).voucherId();}
            db.update("UPDATE finance_procurement_ap_recognition_lines SET reversal_voucher_id=? WHERE recognition_id=? AND candidate_id=?",reversal,id,row.get("id"));
            db.update("UPDATE finance_procurement_payable_candidates SET status='PENDING',ledger_id=NULL,recognition_id=NULL WHERE id=?",row.get("id"));
        }
        db.update("UPDATE finance_procurement_ap_recognitions SET status='REVERSED',reversed_by=?,reversed_at=now(),reverse_reason=? WHERE id=?",current.requireId(),reason,id);return recognition(id);
    }

    @Transactional(readOnly=true) public Map<String,Object> operation(UUID request){read();var rows=db.queryForList("SELECT id FROM finance_procurement_ap_recognitions WHERE request_id=? AND submitted_by=?",request,current.requireId());if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"本人原请求尚无可读取回执，请保留原编号及完整内容核对");return recognition((UUID)rows.getFirst().get("id"));}
    @Transactional(readOnly=true) public Map<String,Object> recognition(UUID id){read();var row=new LinkedHashMap<>(batch(id,false));for(String key:List.of("payload_hash","file_provider","file_key","file_version")){row.remove(key);}var lines=db.queryForList("SELECT l.*,c.source_type,c.source_id,c.bill_no,c.commercial_date,c.due_date FROM finance_procurement_ap_recognition_lines l JOIN finance_procurement_payable_candidates c ON c.id=l.candidate_id WHERE l.recognition_id=? ORDER BY c.commercial_date,c.bill_no,c.id",id);lines.forEach(com.uten.imp.common.report.ReportQueryKit::includeDecimalTexts);row.put("lines",lines);return row;}
    @Transactional(readOnly=true) public Map<String,Object> recognitions(UUID supplier,UUID currency,int page,int size){
        read();int p=Math.max(1,page),s=Math.max(1,Math.min(100,size));var args=new ArrayList<Object>();String where=" WHERE true";
        if(supplier!=null){where+=" AND r.supplier_id=?";args.add(supplier);}if(currency!=null){where+=" AND r.currency_id=?";args.add(currency);}
        long total=db.queryForObject("SELECT count(*) FROM finance_procurement_ap_recognitions r"+where,Long.class,args.toArray());args.add(s);args.add((long)(p-1)*s);
        var rows=db.queryForList("SELECT r.id,r.effective_date AS \"effectiveDate\",r.status,r.source_reference AS \"sourceReference\",r.file_name AS \"fileName\",r.counterpart_confirmed_by AS \"counterpartConfirmedBy\",r.counterpart_confirmed_date AS \"counterpartConfirmedDate\",r.created_at AS \"createdAt\" FROM finance_procurement_ap_recognitions r"+where+" ORDER BY r.created_at DESC,r.id LIMIT ? OFFSET ?",args.toArray());
        return Map.of("items",rows,"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }
    @Transactional(readOnly=true) public byte[] confirmationFile(UUID id){read();var row=batch(id,false);return documents.read(new ImmutableDocumentStore.Reference(row.get("file_provider").toString(),row.get("file_key").toString(),Objects.toString(row.get("file_version"),null),((Number)row.get("file_size")).longValue(),row.get("file_sha256").toString()));}
    private List<Map<String,Object>> selectCandidates(Submission command){var rows=new ArrayList<Map<String,Object>>();var seen=new HashSet<UUID>();for(var selected:command.candidates().stream().sorted(Comparator.comparing(s->s.candidateId()==null?"":s.candidateId().toString())).toList()){
        if(selected.candidateId()==null||!seen.add(selected.candidateId()))throw invalid("原来源不得重复");var matches=db.queryForList("SELECT * FROM finance_procurement_payable_candidates WHERE id=? FOR UPDATE",selected.candidateId());if(matches.size()!=1)throw conflict("原来源不存在");var row=matches.getFirst();requirePending(row,command.supplierId(),command.currencyId(),command.effectiveDate(),selected.sourceFingerprint());rows.add(row);}return rows;}
    private void requirePending(Map<String,Object> row,Object supplier,Object currency,LocalDate effective,Object fingerprint){if(!"PENDING".equals(row.get("status"))||!Objects.equals(row.get("supplier_id"),supplier)||!Objects.equals(row.get("currency_id"),currency)||!Objects.equals(row.get("source_fingerprint"),fingerprint)||effective.isBefore(date(row.get("accrual_date"))))throw conflict("原来源状态、供应商、币别、金额版本或确认日期已变化，请刷新核对");}
    private Account account(String role,UUID supplier,UUID originalCurrency,LocalDate date){
        var resolved=nativeAccounts.resolve(new NativeFinancialPostingAccountPort.Request(role,null,originalCurrency,new NativeFinancialPostingAccountPort.Party("SUPPLIER",supplier),date));
        if(!resolved.complete()||resolved.auxiliary()==null)throw conflict("请先维护该用途/真实币别/供应商的财务代码及辅助对应："+role);
        return new Account(resolved.styleId(),resolved.accountCode(),resolved.accountingCurrencyId(),resolved.auxiliary());
    }
    private UUID role(String role){Object id=em.createNativeQuery("SELECT system_posting_style_id(:role)").setParameter("role",role).getSingleResult();if(!(id instanceof UUID result))throw conflict("请先维护会计科目用途："+role);return result;}
    private FinanceControlledJournalService.Allocation allocation(Account account,UUID originalCurrency,BigDecimal original,BigDecimal rate,UUID source,String snapshot){return new FinanceControlledJournalService.Allocation(account.code(),account.currency(),account.auxiliary(),source.toString(),1,snapshot,originalCurrency,original,rate);}
    private FinancialAuxiliaryValidationPort.Ref ref(Map<String,Object> row){try{return json.readValue(row.get("auxiliary_snapshot").toString(),FinancialAuxiliaryValidationPort.Ref.class);}catch(Exception e){throw conflict("暂估辅助快照损坏，不能改用当前名称猜配");}}
    private Map<String,Object> batch(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_procurement_ap_recognitions WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw invalid("对账确认不存在");return rows.getFirst();}
    private void policyLock(boolean exclusive){db.query("SELECT "+(exclusive?"pg_advisory_xact_lock":"pg_advisory_xact_lock_shared")+"(hashtextextended(?,0))",rs->{},POLICY_LOCK);}
    private void requestLock(UUID id){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:procurement-first-ap-request:'||?::text,0))",rs->{},id);}
    private void read(){CurrentAuthorityGuard.requireAll("finance_report:view","ar_ap_ledger:view");FinanceCompanyReportAccess.require(access);}
    private void write(){read();CurrentAuthorityGuard.requireAll("supplier_settlement:confirm","finance_post:execute");}
    private int count(String sql,Object...args){return db.queryForObject(sql,Integer.class,args);}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw invalid("无法保存原来源快照");}}
    private static String hash(String value){return ImmutableDocumentStore.digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));}
    private static LocalDate date(Object value){return value==null?null:value instanceof LocalDate d?d:LocalDate.parse(value.toString());}
    private static BigDecimal decimal(Map<String,Object> row,String key){Object v=row.get(key);if(!(v instanceof BigDecimal d))throw conflict("原来源金额缺少证据："+key);return d;}
    private static Short legacy(String type){return (short)(type.startsWith("SUBCONTRACT")?30:type.endsWith("_RETURN")?17:1);}
    private static void reference(String value){if(value==null||value.isBlank()||value.length()>2000)throw invalid("请填写实际来源/确认依据（最多2000字）");}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException forbidden(String message){return new ApiException(ErrorCode.FORBIDDEN,message);}
}
