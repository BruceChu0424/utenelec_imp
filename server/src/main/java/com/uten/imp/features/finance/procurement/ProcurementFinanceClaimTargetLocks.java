package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ReviewTaskTargetLockPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Case lookup is initially read-only: never take a case lock before the owning order header. */
@Component
@RequiredArgsConstructor
public class ProcurementFinanceClaimTargetLocks implements ReviewTaskTargetLockPort {
    private final EntityManager em;
    @Override public String targetType() { return "PROCUREMENT_FINANCE_APPROVE"; }

    @Override public List<Target> resolve(List<String> keys,boolean requireExisting) {
        Map<UUID,String> ids=new LinkedHashMap<>();
        for (String key:keys) {
            try {
                UUID id=UUID.fromString(key);
                if (requireExisting && !id.toString().equals(key)) throw new ApiException(ErrorCode.VALIDATION_FAILED,"财务认领必须使用规范审批任务UUID");
                ids.put(id,key);
            }
            catch (IllegalArgumentException | NullPointerException invalid) {
                if (requireExisting) throw new ApiException(ErrorCode.VALIDATION_FAILED,"财务审批任务ID无效");
            }
        }
        if (ids.isEmpty()) return List.of();
        var rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,order_type,order_id FROM procurement_order_approval_cases WHERE id IN (:ids)
                """).setParameter("ids",ids.keySet()));
        if (requireExisting && rows.size()!=ids.size()) throw unavailable();
        return rows.stream().map(row -> new Target(ids.get((UUID)row[0]),
                ProcurementApprovalProjectionQuery.requireOrderType((String)row[1]),(UUID)row[2],(UUID)row[0])).toList();
    }

    @Override public void lockHeader(Target target,boolean requireReviewable) {
        boolean purchase="PURCHASE".equals(target.aggregateType());
        String table=purchase ? "purchase_orders" : "subcontract_orders";
        String state=requireReviewable ? " AND NOT is_deleted AND status IN (0,1)"
                +(purchase ? " AND NOT COALESCE(is_stopped,FALSE)" : "") : "";
        var rows=em.createNativeQuery("SELECT id FROM "+table+" WHERE id=:id"+state+" FOR UPDATE")
                .setParameter("id",target.aggregateId()).getResultList();
        if (requireReviewable && rows.isEmpty()) throw unavailable();
    }

    @Override public void lockTarget(Target target,boolean requireReviewable) {
        var rows=em.createNativeQuery("""
                SELECT id FROM procurement_order_approval_cases
                WHERE id=:id AND order_type=:type AND order_id=:orderId
                """+(requireReviewable ? " AND status='PENDING'" : "")+" FOR UPDATE")
                .setParameter("id",target.targetId()).setParameter("type",target.aggregateType())
                .setParameter("orderId",target.aggregateId()).getResultList();
        if (requireReviewable && rows.isEmpty()) throw unavailable();
    }
    private static ApiException unavailable() { return new ApiException(ErrorCode.CONFLICT,"审批任务或订货单已不在待财务审核状态，请刷新"); }
}
