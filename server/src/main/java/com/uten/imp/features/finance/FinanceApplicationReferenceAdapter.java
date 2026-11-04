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
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void requireApprovedMatch(Reference ref){
        if(!Set.of("EXPENSE","PAYMENT").contains(ref.type())||ref.actor()==null||ref.actor().isVisitor())throw new ApiException(ErrorCode.FORBIDDEN);
        String authority="EXPENSE".equals(ref.type())?"finance_expense:view":"finance_payment:view";
        if(!ref.actor().getPermissions().contains(authority))throw new ApiException(ErrorCode.FORBIDDEN);
        String table="PAYMENT".equals(ref.type())?"finance_payments":"finance_expenses";
        var rows=jdbc.queryForList("SELECT * FROM "+table+" WHERE id=? AND NOT is_deleted FOR UPDATE",ref.documentId());
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"财务单不存在");var finance=rows.getFirst();
        access.requireReadable((UUID)finance.get("maker_id"),"财务单不存在");
        if(((Number)finance.get("status")).intValue()!=1||((BigDecimal)finance.get("amount_local")).compareTo(ref.amount())!=0||!ref.paymentDate().equals(((java.sql.Date)finance.get("bill_date")).toLocalDate()))throw new ApiException(ErrorCode.VALIDATION_FAILED,"关联财务单须已审核，金额及付款日期须与申请一致");
        if(ref.supplierId()!=null&&(!"PAYMENT".equals(ref.type())||!ref.supplierId().equals(finance.get("supplier_id"))))throw new ApiException(ErrorCode.VALIDATION_FAILED,"关联付款单的供应商与申请不一致");
        if("EXPENSE".equals(ref.type())&&Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM expense_claims WHERE finance_expense_id=? AND NOT is_deleted)",Boolean.class,ref.documentId())))throw new ApiException(ErrorCode.VALIDATION_FAILED,"该费用单已经用于员工报销，不能重复登记");
    }
    private static final String PREPAYMENT_SOURCE="""
        payment.status=1 AND NOT payment.is_deleted AND payment.legacy_id IS NULL
        AND payment.legacy_import_run_id IS NULL AND payment.amount_authority_version IN(1,2)
        AND EXISTS(SELECT 1 FROM ar_ap_ledger ledger WHERE ledger.source_doc_id=payment.id
          AND ledger.source_doc_type='DIRECT_PAYMENT' AND ledger.direction='AP'
          AND ledger.open_item_kind='PREPAYMENT' AND ledger.status=1 AND NOT ledger.is_deleted
          AND ledger.legacy_id IS NULL AND ledger.legacy_import_run_id IS NULL
          AND ledger.supplier_id=payment.supplier_id AND ledger.amount_original_local=0
          AND ledger.amount_received_local=payment.amount_local)
        AND NOT EXISTS(SELECT 1 FROM finance_payment_lines line WHERE line.payment_id=payment.id)
        """;
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
            " AND payment.supplier_id="+alias+".supplier_id AND payment.amount_local="+alias+".amount"+
            " AND payment.bill_date=CAST("+alias+".fields->>'paymentDate' AS date) AND ("+scope.sql()+")"+
            " AND NOT EXISTS(SELECT 1 FROM business_applications linked WHERE linked.finance_document_type='PAYMENT'"+
            " AND linked.finance_document_id=payment.id AND linked.id<>"+alias+".id))",scope.parameters());
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void requireApprovedPrepaymentMatch(Reference ref){
        if(!"PAYMENT".equals(ref.type())||ref.supplierId()==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"供应商预付只能关联真实供应商预付款，不能费用化");
        requireApprovedMatch(ref);
        var locked=jdbc.queryForList("SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND source_doc_type='DIRECT_PAYMENT' FOR SHARE",ref.documentId());
        if(locked.isEmpty())throw new ApiException(ErrorCode.CONFLICT,"未找到该付款的供应商预付资产来源");
        var rows=jdbc.queryForList("SELECT payment.id FROM finance_payments payment WHERE payment.id=? AND "+PREPAYMENT_SOURCE,ref.documentId());
        if(rows.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"该付款不是已核实的供应商预付款；普通应付款核销、历史待核记录和费用单不能用于预付入账");
    }
    @Override public CandidatePage prepaymentCandidates(UUID applicationId,UUID supplier,BigDecimal amount,java.time.LocalDate date,AuthUser actor,int page,int size,String keyword){
        var scope=financeScope(actor);var args=new HashMap<String,Object>(scope.parameters());
        args.put("applicationId",applicationId);args.put("supplier",supplier);args.put("amount",amount);args.put("paid",date);
        String where=PREPAYMENT_SOURCE+" AND payment.supplier_id=:supplier AND payment.amount_local=:amount AND payment.bill_date=:paid AND ("+scope.sql()+") AND NOT EXISTS(SELECT 1 FROM business_applications linked WHERE linked.finance_document_type='PAYMENT' AND linked.finance_document_id=payment.id AND linked.id<>:applicationId)";
        if(keyword!=null&&!keyword.isBlank()){if(keyword.trim().length()>200)throw new ApiException(ErrorCode.VALIDATION_FAILED,"搜索内容过长");where+=" AND payment.bill_no ILIKE :keyword ESCAPE '\\'";args.put("keyword",KeywordSearch.containsPattern(keyword.trim()));}
        var named=new NamedParameterJdbcTemplate(jdbc);long total=named.queryForObject("SELECT count(*) FROM finance_payments payment WHERE "+where,args,Long.class);
        int s=Math.clamp(size,1,100);args.put("limit",s);args.put("offset",(long)(Math.max(1,page)-1)*s);
        var rows=named.query("SELECT payment.id,payment.bill_no,payment.bill_date,payment.amount_local FROM finance_payments payment WHERE "+where+" ORDER BY payment.bill_date,payment.bill_no,payment.id LIMIT :limit OFFSET :offset",args,(r,n)->new Candidate(r.getObject(1,UUID.class),r.getString(2),r.getDate(3).toLocalDate(),r.getBigDecimal(4)));
        return new CandidatePage(rows,total);
    }
}
