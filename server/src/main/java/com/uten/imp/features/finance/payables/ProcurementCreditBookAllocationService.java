package com.uten.imp.features.finance.payables;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ProcurementCreditBookAllocationPort;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** One database plan is also checked at document insertion and offset application. */
@Service
@RequiredArgsConstructor
public class ProcurementCreditBookAllocationService implements ProcurementCreditBookAllocationPort {
    @org.springframework.beans.factory.annotation.Autowired private com.uten.imp.application.port.NativeFinancialPostingAccountPort nativeAccounts;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SupplierClosedPeriodGuard closedPeriodGuard;
    private static final ObjectMapper JSON = new ObjectMapper();

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public BookAllocationPlan plan(UUID sourceApLedgerId, BigDecimal actualAmountOriginal) {
        tx.bind();
        BigDecimal actual=FinancialExactAmount.require(actualAmountOriginal,"供应商实际贷项原币");
        if(actual.signum()<=0)throw new ApiException(ErrorCode.VALIDATION_FAILED,"供应商实际贷项原币必须大于0");
        Object value=em.createNativeQuery("SELECT fn_plan_procurement_credit_book(:source,:actual)::text")
                .setParameter("source",sourceApLedgerId).setParameter("actual",actual).getSingleResult();
        try { return JSON.readValue(value.toString(),BookAllocationPlan.class); }
        catch(JsonProcessingException ex) { throw new ApiException(ErrorCode.CONFLICT,"应付账面分摊计划的内容不正确，请核对后重试"); }
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public BookAllocationPlan planPending(UUID sourceCandidateId,BigDecimal actualAmountOriginal){
        tx.bind();BigDecimal actual=FinancialExactAmount.require(actualAmountOriginal,"供应商实际贷项原币");
        if(sourceCandidateId==null||actual.signum()<=0)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请明确选择真实暂估来源并填写大于零的实际贷项");
        Object value=em.createNativeQuery("SELECT fn_plan_procurement_pending_credit_book(:source,:actual)::text")
                .setParameter("source",sourceCandidateId).setParameter("actual",actual).getSingleResult();
        try{return JSON.readValue(value.toString(),BookAllocationPlan.class);}
        catch(JsonProcessingException error){throw new ApiException(ErrorCode.CONFLICT,"原暂估账面分摊计划无法读取，请核对真实来源");}
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID applyOffset(UUID caseId, UUID creditDocumentId, UUID creditLedgerId,
            BookAllocationPlan plan, LocalDate effectiveDate, String reason) {
        tx.bind();
        if(plan.sourceCandidateId()!=null){
            if(plan.sourceApLedgerId()!=null||plan.offsetOriginal().signum()!=0||plan.offsetLocal().signum()!=0)
                throw new ApiException(ErrorCode.CONFLICT,"暂估来源不能伪装为正式应付抵销目标");
            var identities=com.uten.imp.common.util.NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source.supplier_id,source.currency_id FROM finance_procurement_payable_candidates source
                JOIN procurement_iqc_credit_documents document ON document.source_candidate_id=source.id AND document.id=:document
                JOIN ar_ap_ledger credit ON credit.id=:credit AND credit.source_doc_id=document.id AND credit.direction='AP'
                  AND credit.status=1 AND NOT credit.is_deleted AND credit.supplier_id=source.supplier_id AND credit.currency_id=source.currency_id
                  AND credit.amount_original=-document.amount_original AND credit.amount_original_local=-document.amount_local
                WHERE source.id=:source AND source.status='PENDING'
                """).setParameter("source",plan.sourceCandidateId()).setParameter("document",creditDocumentId).setParameter("credit",creditLedgerId));
            if(identities.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"实际贷项与原暂估来源的供应商、币别或金额不一致");
            var identity=identities.getFirst();closedPeriodGuard.requireOpen((UUID)identity[0],(UUID)identity[1],effectiveDate,"实际供应商贷项确认");
            return null; // A real negative AP exists; no positive AP or offset was fabricated.
        }
        Object[] identity=(Object[])em.createNativeQuery("SELECT supplier_id,currency_id FROM ar_ap_ledger WHERE id=:id")
                .setParameter("id",plan.sourceApLedgerId()).getSingleResult();
        closedPeriodGuard.requireOpen((UUID)identity[0],(UUID)identity[1],effectiveDate,"供应商实际贷项抵销");
        try {
            Object value=em.createNativeQuery("SELECT fn_apply_procurement_credit_book_offset(:caseId,:document,:ledger,CAST(:plan AS jsonb),:effectiveDate,:reason)")
                    .setParameter("caseId",caseId).setParameter("document",creditDocumentId)
                    .setParameter("ledger",creditLedgerId).setParameter("plan",JSON.writeValueAsString(plan))
                    .setParameter("effectiveDate",effectiveDate).setParameter("reason",reason).getSingleResult();
            UUID allocation=value==null?null:(UUID)value;
            if(allocation!=null&&nativeAccounts!=null)nativeAccounts.supplierOffsetApplied(allocation);
            return allocation;
        } catch(JsonProcessingException ex) { throw new ApiException(ErrorCode.CONFLICT,"应付账面分摊计划的内容不正确，请核对后重试"); }
    }
}
