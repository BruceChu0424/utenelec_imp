package com.uten.imp.features.sales.shipment;

import com.uten.imp.application.port.ReviewTaskTargetLockPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Claim-only operations never enter inventory or source-order locks after the shipment header. */
@Component
@RequiredArgsConstructor
public class ShipmentFinanceClaimTargetLocks implements ReviewTaskTargetLockPort {
    private final EntityManager em;
    @Override public String targetType() { return CustomerShipmentPolicy.CLAIM_TYPE; }
    @Override public List<Target> resolve(List<String> keys,boolean requireExisting) {
        List<Target> result=new ArrayList<>();
        for (String key:keys) {
            UUID id;
            try { id=UUID.fromString(key); }
            catch (IllegalArgumentException | NullPointerException invalid) {
                if (requireExisting) throw new ApiException(ErrorCode.VALIDATION_FAILED,"出货单ID无效");
                continue;
            }
            if (requireExisting && !id.toString().equals(key)) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请使用有效出货单ID");
            result.add(new Target(key,"SALES_SHIPMENT",id,id));
        }
        return result;
    }
    @Override public void lockHeader(Target target,boolean requireReviewable) {
        String state=requireReviewable ? """
                 AND NOT is_deleted AND status=0 AND NOT rejected AND finance_audit=0
                 AND NOT finance_rejected AND warehouse_work_status='PENDING_PICK'
                 AND shipment_kind<>'LEGACY'
                 AND (finance_gate_version<2 OR (sales_confirmed_at IS NOT NULL
                      AND sales_confirmed_revision=review_revision))
                """ : "";
        var rows=em.createNativeQuery("SELECT id FROM sales_shipments WHERE id=:id"+state+" FOR UPDATE")
                .setParameter("id",target.aggregateId()).getResultList();
        if (requireReviewable && rows.isEmpty()) throw new ApiException(ErrorCode.CONFLICT,"出货单已不在待财务审核状态，请刷新");
    }
    @Override public void lockTarget(Target target,boolean requireReviewable) { }
}
