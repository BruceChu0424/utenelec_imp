package com.uten.imp.features.production;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.application.port.ProductionDocumentReadScopePort;
import org.springframework.stereotype.Component;

/**
 * 生产单据行级访问策略：按制单人(maker_id)隔离。薄壳固定 scope=production_plan /
 * viewAll=production_plan:view:all，判定逻辑继承自 {@link DocumentAccessPolicy}。
 *
 * <p>覆盖生产计划与生产日报（归属列均为 maker_id）。MRP 自审核(autoApproveForOrchestrator)
 * 等系统内部路径豁免本隔离。
 */
@Component
public class ProductionDocumentAccessPolicy extends DocumentAccessPolicy implements ProductionDocumentReadScopePort {

    public static final String SCOPE = "production_plan";
    public static final String VIEW_ALL = "production_plan:view:all";

    public ProductionDocumentAccessPolicy(OwnerVisibility ownerVisibility,
                                          SecurityContextCurrentUser currentUser) {
        super(SCOPE, VIEW_ALL, ownerVisibility, currentUser);
    }

    /** Existing approval pool stays unchanged; observers use their ordinary plan read scope. */
    public NativeReadScope approvalRequestReadScope(String segmentExpression) {
        if (hasAuthority("production_plan:approve")) return new NativeReadScope("1=1", null, java.util.Set.of());
        if (!hasAuthority("production_plan:view")) throw new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.FORBIDDEN, "没有生产计划查看权限");
        NativeReadScope owners = nativeReadScope("read_plan.maker_id", "requestReadOwners");
        return new NativeReadScope("EXISTS (SELECT 1 FROM production_execution_segments read_segment "
                + "JOIN production_plans read_plan ON read_plan.id=read_segment.plan_id "
                + "WHERE read_segment.id=" + segmentExpression + " AND " + owners.predicate() + ")",
                owners.parameterName(), owners.owners());
    }

    public boolean canObserveRequestSegment(jakarta.persistence.EntityManager em, java.util.UUID segmentId) {
        if (!hasAuthority("production_plan:view")) return false;
        NativeReadScope scope = approvalRequestReadScope("CAST(:observedSegment AS uuid)");
        var query = em.createNativeQuery("SELECT CASE WHEN " + scope.predicate() + " THEN 1 ELSE 0 END");
        if (scope.predicate().contains(":observedSegment")) query.setParameter("observedSegment", segmentId);
        scope.bind(query);
        return ((Number) query.getSingleResult()).intValue() == 1;
    }
}
