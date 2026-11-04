package com.uten.imp.features.finance;
import com.uten.imp.application.port.FinanceApplicationReferencePort;
import com.uten.imp.common.web.*;
import com.uten.imp.common.util.KeywordSearch;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.util.*;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import com.uten.imp.security.AuthUser;
@Component
@RequiredArgsConstructor
public class FinanceApplicationReferenceAdapter implements FinanceApplicationReferencePort {
    private final JdbcTemplate jdbc;
    private final FinanceDocumentAccessPolicy access;
    private final com.uten.imp.application.port.NativeApplicationOriginPort origins;
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void requireApprovedMatch(Reference ref){
        if(!Set.of("EXPENSE","PAYMENT").contains(ref.type())||ref.actor()==null||ref.actor().isVisitor())throw new ApiException(ErrorCode.FORBIDDEN);
        String authority="EXPENSE".equals(ref.type())?"finance_expense:view":"finance_payment:view";
        if(!ref.actor().getPermissions().contains(authority))throw new ApiException(ErrorCode.FORBIDDEN);
        String table="PAYMENT".equals(ref.type())?"finance_payments":"finance_expenses";
        var rows=jdbc.queryForList("SELECT * FROM "+table+" WHERE id=? AND NOT is_deleted FOR UPDATE",ref.documentId());
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"财务单不存在");var finance=rows.getFirst();
        access.requireReadable((UUID)finance.get("maker_id"),"财务单不存在");
        if(Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM finance_application_executions WHERE doc_type=? AND doc_id=?)",Boolean.class,ref.type(),ref.documentId())))
            throw new ApiException(ErrorCode.CONFLICT,"该财务单已有原申请执行回执，请从原申请查阅，不能再关联另一申请");
        boolean original=ref.amountBasis()==com.uten.imp.application.port.NativeApplicationOriginPort.AmountBasis.ORIGINAL;
        if(ref.amountBasis()==com.uten.imp.application.port.NativeApplicationOriginPort.AmountBasis.NOT_APPLICABLE||ref.amount()==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"无金额的来源不能作为付款金额关联");
        if(original&&(ref.currencyId()==null||!ref.currencyId().equals(finance.get("currency_id"))))throw new ApiException(ErrorCode.VALIDATION_FAILED,"关联财务单的原币与原申请不一致，不能按本币金额替代");
        if(((Number)finance.get("status")).intValue()!=1||!(finance.get(original?"amount_original":"amount_local") instanceof BigDecimal actual)||actual.compareTo(ref.amount())!=0||!ref.paymentDate().equals(((java.sql.Date)finance.get("bill_date")).toLocalDate()))throw new ApiException(ErrorCode.VALIDATION_FAILED,original?"关联财务单须已审核，原币金额及实际付款日期须与申请一致":"关联财务单须已审核，本币金额及付款日期须与申请一致");
        if(ref.supplierId()!=null&&(!"PAYMENT".equals(ref.type())||!ref.supplierId().equals(finance.get("supplier_id"))))throw new ApiException(ErrorCode.VALIDATION_FAILED,"关联付款单的供应商与申请不一致");
        if("EXPENSE".equals(ref.type())&&Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM expense_claims WHERE finance_expense_id=? AND NOT is_deleted)",Boolean.class,ref.documentId())))throw new ApiException(ErrorCode.VALIDATION_FAILED,"该费用单已经用于员工报销，不能重复登记");
        if(!ref.obligations().isEmpty()){
            if(!original||!"PAYMENT".equals(ref.type())||ref.supplierId()==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"原应付义务只能关联同供应商、同原币的采购付款");
            var lines=jdbc.queryForList("SELECT applied_ledger_id,amount_original FROM finance_payment_lines WHERE payment_id=? ORDER BY applied_ledger_id FOR SHARE",ref.documentId());
            if(lines.size()!=ref.obligations().size())throw new ApiException(ErrorCode.VALIDATION_FAILED,"付款核销项与原申请逐项义务不一致");
            for(var obligation:ref.obligations())if(lines.stream().noneMatch(line->obligation.ledgerId().equals(line.get("applied_ledger_id"))&&line.get("amount_original") instanceof BigDecimal value&&value.compareTo(obligation.amountOriginal())==0))throw new ApiException(ErrorCode.VALIDATION_FAILED,"付款未逐项对应原应付来源及原币申请金额");
            var ledger=jdbc.queryForList("SELECT supplier_id,currency_id,direction,open_item_kind,status,is_deleted FROM ar_ap_ledger WHERE id IN(SELECT applied_ledger_id FROM finance_payment_lines WHERE payment_id=?) FOR SHARE",ref.documentId());
            if(ledger.size()!=lines.size()||ledger.stream().anyMatch(row->!ref.supplierId().equals(row.get("supplier_id"))||!ref.currencyId().equals(row.get("currency_id"))||!"AP".equals(row.get("direction"))||!"PAYABLE".equals(row.get("open_item_kind"))||((Number)row.get("status")).intValue()!=1||Boolean.TRUE.equals(row.get("is_deleted"))))throw new ApiException(ErrorCode.VALIDATION_FAILED,"原应付义务身份已变化，不能用其他往来或预付替代");
        }
    }
    private static final String NATIVE_ADVANCE="""
        payment.amount_authority_version=2 AND EXISTS(SELECT 1 FROM finance_supplier_advances advance
          WHERE advance.payment_id=payment.id AND advance.status='OPEN' AND advance.reversed_at IS NULL
            AND advance.supplier_id=payment.supplier_id AND advance.currency_id=payment.currency_id
            AND advance.amount_original=payment.amount_original AND advance.amount_local=payment.amount_local
            AND advance.effective_date=payment.bill_date AND advance.style_id=payment.gl_ap_style_id
            AND EXISTS(SELECT 1 FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id
              JOIN finance_gl_entry_allocations allocation ON allocation.entry_id=entry.id
              WHERE voucher.source='AUTO' AND voucher.source_type='PAYMENT' AND voucher.source_doc_id=payment.id
                AND voucher.status=1 AND NOT voucher.is_deleted AND NOT entry.is_deleted
                AND entry.line_no=1 AND entry.direction=1 AND entry.style_id=advance.style_id
                AND entry.amount=advance.amount_local AND allocation.account_code=advance.account_code
                AND allocation.auxiliary_id=advance.auxiliary_id AND allocation.party_id_snapshot=advance.supplier_id
                AND allocation.original_currency_id=advance.currency_id AND allocation.currency_id=advance.accounting_currency_id
                AND allocation.amount_original=advance.amount_original AND allocation.amount_local=advance.amount_local))
        """;
    private static final String LEGACY_PREPAYMENT="""
        (SELECT count(*) FROM ar_ap_ledger ledger WHERE ledger.source_doc_id=payment.id
          AND ledger.source_doc_type='DIRECT_PAYMENT' AND ledger.direction='AP'
          AND ledger.open_item_kind='PREPAYMENT' AND ledger.status=1 AND NOT ledger.is_deleted
          AND ledger.legacy_id IS NULL AND ledger.legacy_import_run_id IS NULL
          AND ledger.supplier_id=payment.supplier_id AND ledger.currency_id=payment.currency_id
          AND ledger.amount_original=0 AND ledger.amount_original_local=0
          AND ledger.amount_received_original=payment.amount_original AND ledger.amount_received_local=payment.amount_local)=1
        """;
    private static final String PREPAYMENT_SOURCE="""
        payment.status=1 AND NOT payment.is_deleted AND payment.legacy_id IS NULL
        AND payment.legacy_import_run_id IS NULL AND payment.amount_authority_version IN(1,2)
        AND NOT EXISTS(SELECT 1 FROM finance_application_executions original_execution
          WHERE original_execution.doc_type='PAYMENT' AND original_execution.doc_id=payment.id)
        AND NOT EXISTS(SELECT 1 FROM finance_payment_lines line WHERE line.payment_id=payment.id)
        AND EXISTS(SELECT 1 FROM gl_vouchers voucher WHERE voucher.source='AUTO' AND voucher.source_type='PAYMENT'
          AND voucher.source_doc_id=payment.id AND voucher.status=1 AND NOT voucher.is_deleted
          AND (SELECT count(*) FROM gl_entries entry WHERE entry.voucher_id=voucher.id AND NOT entry.is_deleted)>=2
          AND (SELECT sum(entry.amount*entry.direction) FROM gl_entries entry WHERE entry.voucher_id=voucher.id AND NOT entry.is_deleted)=0
          AND EXISTS(SELECT 1 FROM gl_entries entry WHERE entry.voucher_id=voucher.id AND NOT entry.is_deleted
            AND entry.direction=1 AND entry.amount=payment.amount_local)) AND
        """+"((("+NATIVE_ADVANCE+") AND NOT EXISTS(SELECT 1 FROM ar_ap_ledger ledger WHERE ledger.source_doc_id=payment.id AND ledger.source_doc_type='DIRECT_PAYMENT')) OR (("+LEGACY_PREPAYMENT+") AND NOT EXISTS(SELECT 1 FROM finance_supplier_advances advance WHERE advance.payment_id=payment.id)))";
    private Condition financeScope(AuthUser actor){
        if(actor==null||actor.isVisitor()||!actor.getPermissions().contains("finance_payment:view"))return new Condition("FALSE",Map.of());
        var old=SecurityContextHolder.getContext();var context=SecurityContextHolder.createEmptyContext();
        context.setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
        SecurityContextHolder.setContext(context);
        try{
            var scope=access.nativeReadScope("payment.maker_id","prepaymentFinanceOwners");
            if(scope==null)return new Condition("FALSE",Map.of());
            return new Condition(scope.predicate(),scope.parameterName()==null?Map.of():Map.of(scope.parameterName(),scope.owners()));
        }finally{SecurityContextHolder.setContext(old);}
    }
    @Override public Condition prepaymentMatchingCondition(String alias,AuthUser actor){
        if(alias==null||!alias.matches("[a-z][a-z0-9_]*"))throw new IllegalArgumentException("Server-owned alias required");
        var scope=financeScope(actor);
        return new Condition("EXISTS(SELECT 1 FROM finance_payments payment WHERE "+PREPAYMENT_SOURCE+
            " AND payment.supplier_id="+alias+".supplier_id AND "+matchingAmountSql(alias)+
            " AND payment.bill_date=CAST("+alias+".fields->>'paymentDate' AS date) AND ("+scope.sql()+")"+
            " AND NOT EXISTS(SELECT 1 FROM business_applications linked WHERE linked.finance_document_type='PAYMENT'"+
            " AND linked.finance_document_id=payment.id AND linked.id<>"+alias+".id))",scope.parameters());
    }
    private String matchingAmountSql(String alias){return "(CASE WHEN EXISTS(SELECT 1 FROM finance_application_native_mappings origin WHERE origin.native_kind='BUSINESS_APPLICATION' AND origin.native_id="+alias+".id AND origin.amount_basis='ORIGINAL') THEN EXISTS(SELECT 1 FROM finance_application_native_mappings origin WHERE origin.native_kind='BUSINESS_APPLICATION' AND origin.native_id="+alias+".id AND origin.amount_basis='ORIGINAL' AND payment.currency_id=origin.original_currency_id AND payment.amount_original="+alias+".amount) ELSE payment.amount_local="+alias+".amount END)";}
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void requireApprovedPrepaymentMatch(Reference ref){
        if(!"PAYMENT".equals(ref.type())||ref.supplierId()==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"供应商预付只能关联真实供应商预付款，不能费用化");
        requireApprovedMatch(ref);
        jdbc.queryForList("SELECT payment_id FROM finance_supplier_advances WHERE payment_id=? FOR SHARE",ref.documentId());
        jdbc.queryForList("SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND source_doc_type='DIRECT_PAYMENT' FOR SHARE",ref.documentId());
        var rows=jdbc.queryForList("SELECT payment.id FROM finance_payments payment WHERE payment.id=? AND "+PREPAYMENT_SOURCE,ref.documentId());
        if(rows.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"该付款不是已核实的供应商预付款；普通应付款核销、历史待核记录和费用单不能用于预付入账");
        if(ref.applicationId()!=null)capturePrepaymentProof(ref);
    }
    private void capturePrepaymentProof(Reference ref){
        String facts=jdbc.queryForObject("""
            SELECT jsonb_build_object('branch',CASE WHEN EXISTS(SELECT 1 FROM finance_supplier_advances WHERE payment_id=payment.id)
              THEN 'NATIVE_ADVANCE_V2' ELSE 'LEGACY_PREPAYMENT_LEDGER' END,
              'payment',jsonb_build_object('id',payment.id,'authorityVersion',payment.amount_authority_version,
                'supplierId',payment.supplier_id,'currencyId',payment.currency_id,'amountOriginal',payment.amount_original::text,
                'amountLocal',payment.amount_local::text,'billDate',payment.bill_date,'status',payment.status),
              'advance',(SELECT to_jsonb(advance)-'creation_tx' FROM finance_supplier_advances advance WHERE advance.payment_id=payment.id),
              'legacyLedger',(SELECT jsonb_agg(to_jsonb(ledger) ORDER BY ledger.id) FROM ar_ap_ledger ledger
                WHERE ledger.source_doc_id=payment.id AND ledger.source_doc_type='DIRECT_PAYMENT'),
              'vouchers',(SELECT jsonb_agg(jsonb_build_object('id',voucher.id,'source',voucher.source,'type',voucher.source_type,
                'sourceId',voucher.source_doc_id,'status',voucher.status,'entries',(SELECT jsonb_agg(jsonb_build_object(
                  'id',entry.id,'direction',entry.direction,'amount',entry.amount::text,'styleId',entry.style_id,
                  'allocations',(SELECT jsonb_agg(to_jsonb(allocation) ORDER BY allocation.allocation_no)
                    FROM finance_gl_entry_allocations allocation WHERE allocation.entry_id=entry.id)) ORDER BY entry.line_no,entry.id)
                  FROM gl_entries entry WHERE entry.voucher_id=voucher.id AND NOT entry.is_deleted)) ORDER BY voucher.id)
                FROM gl_vouchers voucher WHERE voucher.source='AUTO' AND voucher.source_type='PAYMENT'
                  AND voucher.source_doc_id=payment.id AND voucher.status=1 AND NOT voucher.is_deleted))::text
            FROM finance_payments payment WHERE payment.id=?
            """,String.class,ref.documentId());
        String hash=com.uten.imp.common.storage.ImmutableDocumentStore.digest(facts.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        jdbc.update("""
            INSERT INTO finance_native_application_payment_proofs(application_id,submission_round,payment_id,source_branch,
              amount_basis,source_fingerprint,source_facts,actor_id,actor_employee_id)
            SELECT app.id,app.round,?,(?::jsonb)->>'branch',?,?,?::jsonb,?,? FROM business_applications app WHERE app.id=?
            ON CONFLICT(application_id,submission_round,payment_id) DO NOTHING
            """,ref.documentId(),facts,ref.amountBasis().name(),hash,facts,ref.actor().getId(),ref.actor().getEmployeeId(),ref.applicationId());
        var proof=jdbc.queryForList("SELECT source_fingerprint FROM finance_native_application_payment_proofs proof JOIN business_applications app ON app.id=proof.application_id AND app.round=proof.submission_round WHERE proof.application_id=? AND proof.payment_id=?",ref.applicationId(),ref.documentId());
        if(proof.size()!=1||!hash.equals(proof.getFirst().get("source_fingerprint")))throw new ApiException(ErrorCode.CONFLICT,"本轮原付款来源与已记录依据不一致，请核对原付款，不重复关联");
    }
    @Override public CandidatePage prepaymentCandidates(UUID applicationId,UUID supplier,BigDecimal amount,java.time.LocalDate date,AuthUser actor,int page,int size,String keyword){
        var scope=financeScope(actor);var args=new HashMap<String,Object>(scope.parameters());
        args.put("applicationId",applicationId);args.put("supplier",supplier);args.put("amount",amount);args.put("paid",date);
        var origin=origins.origin("BUSINESS_APPLICATION",applicationId);boolean original=origin!=null&&origin.amountBasis()==com.uten.imp.application.port.NativeApplicationOriginPort.AmountBasis.ORIGINAL;
        if(original)args.put("originalCurrency",origin.currencyId());
        String amountSql=original?"payment.amount_original=:amount AND payment.currency_id=:originalCurrency":"payment.amount_local=:amount";
        String where=PREPAYMENT_SOURCE+" AND payment.supplier_id=:supplier AND "+amountSql+" AND payment.bill_date=:paid AND ("+scope.sql()+") AND NOT EXISTS(SELECT 1 FROM business_applications linked WHERE linked.finance_document_type='PAYMENT' AND linked.finance_document_id=payment.id AND linked.id<>:applicationId)";
        if(keyword!=null&&!keyword.isBlank()){if(keyword.trim().length()>200)throw new ApiException(ErrorCode.VALIDATION_FAILED,"搜索内容过长");where+=" AND payment.bill_no ILIKE :keyword ESCAPE '\\'";args.put("keyword",KeywordSearch.containsPattern(keyword.trim()));}
        var named=new NamedParameterJdbcTemplate(jdbc);long total=named.queryForObject("SELECT count(*) FROM finance_payments payment WHERE "+where,args,Long.class);
        int s=Math.clamp(size,1,100);args.put("limit",s);args.put("offset",(long)(Math.max(1,page)-1)*s);
        var rows=named.query("SELECT payment.id,payment.bill_no,payment.bill_date,payment."+(original?"amount_original":"amount_local")+" FROM finance_payments payment WHERE "+where+" ORDER BY payment.bill_date,payment.bill_no,payment.id LIMIT :limit OFFSET :offset",args,(r,n)->new Candidate(r.getObject(1,UUID.class),r.getString(2),r.getDate(3).toLocalDate(),r.getBigDecimal(4),original?origin.amountBasis():com.uten.imp.application.port.NativeApplicationOriginPort.AmountBasis.LOCAL,original?origin.currencyCode():null));
        return new CandidatePage(rows,total);
    }
}
