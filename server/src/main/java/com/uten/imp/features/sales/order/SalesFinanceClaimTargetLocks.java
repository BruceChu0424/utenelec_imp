package com.uten.imp.features.sales.order;

import com.uten.imp.application.port.ReviewTaskTargetLockPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** The sales finance pool already has whole-task read scope; current pending state is checked under the sales header lock. */
@Component
@RequiredArgsConstructor
public class SalesFinanceClaimTargetLocks implements ReviewTaskTargetLockPort {
    private final EntityManager em;
    @Override public String targetType() { return "SALES_ORDER_FINANCE_CONFIRM"; }

    @Override public List<Target> resolve(List<String> keys,boolean requireExisting) {
        List<Target> targets=new ArrayList<>();
        for (String key:keys) {
            UUID id;
            try { id=UUID.fromString(key); }
            catch (IllegalArgumentException | NullPointerException invalid) {
                if (requireExisting) throw new ApiException(ErrorCode.VALIDATION_FAILED,"销售订单ID无效");
                continue; // Old malformed/orphan soft claims can still be released.
            }
            if (requireExisting && !id.toString().equals(key)) throw new ApiException(ErrorCode.VALIDATION_FAILED,"财务认领必须使用规范销售订单UUID");
            targets.add(new Target(key,"SALES_ORDER",id,id));
        }
        return targets;
    }

    @Override public void lockHeader(Target target,boolean requireReviewable) {
        String state=requireReviewable ? """
                 AND status=1 AND NOT is_deleted AND NOT finance_confirmed AND NOT finance_rejected
                 AND NOT is_stopped AND (NOT is_closed OR finance_review_revision>0)
                """ : "";
        var rows=em.createNativeQuery("SELECT id FROM sales_orders WHERE id=:id"+state+" FOR UPDATE")
                .setParameter("id",target.aggregateId()).getResultList();
        if (requireReviewable && rows.isEmpty()) throw new ApiException(ErrorCode.CONFLICT,"订单已不在待财务审核状态，请刷新");
    }
    @Override public void lockTarget(Target target,boolean requireReviewable) { /* The sales header is also the review target. */ }
}
