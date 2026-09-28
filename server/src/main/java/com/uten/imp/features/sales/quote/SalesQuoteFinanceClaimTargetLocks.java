package com.uten.imp.features.sales.quote;

import com.uten.imp.application.port.ReviewTaskTargetLockPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 报价核价认领的目标锁(ADR-134): 认领/续租/核价动作前先锁报价表头, 并确认报价仍在「待财务核价」。
 * 核价池本身就有整张报价的读范围, 表头即认领目标。
 */
@Component
@RequiredArgsConstructor
public class SalesQuoteFinanceClaimTargetLocks implements ReviewTaskTargetLockPort {

    public static final String TARGET_TYPE = "SALES_QUOTE_FINANCE_REVIEW";

    private final EntityManager em;

    @Override
    public String targetType() {
        return TARGET_TYPE;
    }

    @Override
    public List<Target> resolve(List<String> keys, boolean requireExisting) {
        List<Target> targets = new ArrayList<>();
        for (String key : keys) {
            UUID id;
            try {
                id = UUID.fromString(key);
            } catch (IllegalArgumentException | NullPointerException invalid) {
                if (requireExisting) throw new ApiException(ErrorCode.VALIDATION_FAILED, "销售报价单ID无效");
                continue; // 旧的畸形认领仍允许释放。
            }
            if (requireExisting && !id.toString().equals(key)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "核价认领必须使用规范的销售报价单UUID");
            }
            targets.add(new Target(key, "SALES_QUOTE", id, id));
        }
        return targets;
    }

    @Override
    public void lockHeader(Target target, boolean requireReviewable) {
        String state = requireReviewable ? " AND status = 2 AND NOT is_deleted" : "";
        var rows = em.createNativeQuery("SELECT id FROM sales_quotes WHERE id = :id" + state + " FOR UPDATE")
                .setParameter("id", target.aggregateId())
                .getResultList();
        if (requireReviewable && rows.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "报价已不在待财务核价状态，请刷新");
        }
    }

    @Override
    public void lockTarget(Target target, boolean requireReviewable) {
        // 报价表头即核价目标, 没有单独的案件行。
    }
}
