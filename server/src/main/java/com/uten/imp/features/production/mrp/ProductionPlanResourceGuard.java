package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 生产计划子资源({@code /api/production/plans/{id}/mrp/**})的对象范围守卫(security-07)。
 *
 * <p>计划主服务按制单人隔离(V233)，但 MRP 预览、预排草案、计划包生命周期由另外几个
 * 服务实现，过去只校验功能权限，任何持 production_plan:view 的部门都能按 id 读写他人计划。
 * 这里与计划详情同一口径：先判可读(越权统一 404，不泄露存在性)，写动作再判可写。
 * 控制器每个处理方法入口都必须先过这里({@code ProductionPlanSubresourceScopeContractTest} 锁定)。
 */
@Component
public class ProductionPlanResourceGuard {

    /** 与计划详情一致：审核人按业务需要可跨人读取待审计划。 */
    private static final String APPROVE_AUTHORITY = "production_plan:approve";

    private final EntityManager em;
    private final ProductionDocumentAccessPolicy access;

    public ProductionPlanResourceGuard(EntityManager em, ProductionDocumentAccessPolicy access) {
        this.em = em;
        this.access = access;
    }

    /** 计划必须存在且在当前主体的读范围内，否则 404。 */
    @Transactional(propagation = Propagation.SUPPORTS, readOnly = true)
    public void requireReadable(UUID planId) {
        access.requireReadable(ownerOf(planId), "生产计划不存在", APPROVE_AUTHORITY);
    }

    /**
     * 写动作：先按读范围判定(越权 404)，再要求本人范围可写或持本动作的全量操作权
     * (越权 403)。
     */
    @Transactional(propagation = Propagation.SUPPORTS, readOnly = true)
    public void requireWritable(UUID planId, String operationAuthority) {
        UUID owner = ownerOf(planId);
        access.requireReadable(owner, "生产计划不存在", APPROVE_AUTHORITY);
        access.requireWritable(owner, "只能操作本人负责的生产计划", operationAuthority);
    }

    private UUID ownerOf(UUID planId) {
        if (planId == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在");
        }
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery("""
                        SELECT plan.maker_id
                        FROM production_plans plan
                        WHERE plan.id = :planId AND plan.is_deleted = FALSE
                        """)
                .setParameter("planId", planId)
                .getResultList();
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在");
        }
        return (UUID) rows.getFirst();
    }
}
