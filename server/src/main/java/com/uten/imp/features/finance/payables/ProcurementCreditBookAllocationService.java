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
        catch(JsonProcessingException ex) { throw new ApiException(ErrorCode.CONFLICT,"应付账面分摊计划格式无效"); }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID applyOffset(UUID caseId, UUID creditDocumentId, UUID creditLedgerId,
            BookAllocationPlan plan, LocalDate effectiveDate, String reason) {
        tx.bind();
        Object[] identity=(Object[])em.createNativeQuery("SELECT supplier_id,currency_id FROM ar_ap_ledger WHERE id=:id")
                .setParameter("id",plan.sourceApLedgerId()).getSingleResult();
        closedPeriodGuard.requireOpen((UUID)identity[0],(UUID)identity[1],effectiveDate,"供应商实际贷项抵销");
        try {
            Object value=em.createNativeQuery("SELECT fn_apply_procurement_credit_book_offset(:caseId,:document,:ledger,CAST(:plan AS jsonb),:effectiveDate,:reason)")
                    .setParameter("caseId",caseId).setParameter("document",creditDocumentId)
                    .setParameter("ledger",creditLedgerId).setParameter("plan",JSON.writeValueAsString(plan))
                    .setParameter("effectiveDate",effectiveDate).setParameter("reason",reason).getSingleResult();
            return value==null?null:(UUID)value;
        } catch(JsonProcessingException ex) { throw new ApiException(ErrorCode.CONFLICT,"应付账面分摊计划格式无效"); }
    }
}
