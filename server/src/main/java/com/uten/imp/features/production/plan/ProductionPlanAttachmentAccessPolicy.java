package com.uten.imp.features.production.plan;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 生产计划附件（工艺图纸、客户样品图、排产确认件）的对象级授权。
 *
 * <p>可读 = 与计划详情同口径（production_plan:view + 制单人归属范围，审核权可旁路归属）；
 * 可管理 = 草稿（含冲销回草稿）且未关闭/中止/取消，并持 production_plan:edit 与可写归属。
 * 确认/删除前锁真实计划行并复核状态，审核后原件只读。</p>
 */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class ProductionPlanAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "PRODUCTION_PLAN";
    private static final short STATUS_DRAFT = 0;
    private final EntityManager em;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionPlanMutationFootprintService mutations;

    @Override public String ownerType() { return OWNER_TYPE; }

    @Override public void requireCanView(UUID ownerId, AuthUser user) {
        readable(plan(ownerId), user);
    }

    @Override public void requireCanManage(UUID ownerId, AuthUser user) {
        editable(plan(ownerId), user);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        editable(plan(ownerId), user);
        var guard = mutations.beginPlan(ownerId, List.of());
        ProductionPlan locked = em.find(ProductionPlan.class, ownerId, LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) throw missing();
        em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
        editable(locked, user);
        guard.verifyUnchanged();
    }

    private ProductionPlan plan(UUID id) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定生产计划");
        ProductionPlan plan = em.find(ProductionPlan.class, id);
        if (plan == null || plan.isDeleted()) throw missing();
        return plan;
    }

    private void readable(ProductionPlan plan, AuthUser user) {
        if (plan.isDeleted() || !has(user, "production_plan:view")) throw missing();
        access.requireReadable(plan.getMakerId(), "生产计划不存在", "production_plan:approve");
    }

    private void editable(ProductionPlan plan, AuthUser user) {
        readable(plan, user);
        if (!has(user, "production_plan:edit")) throw new ApiException(ErrorCode.FORBIDDEN, "缺少生产计划编辑权限");
        access.requireWritable(plan.getMakerId(), "无权修改该生产计划附件");
        boolean draft = plan.getStatus() != null && plan.getStatus() == STATUS_DRAFT;
        if (!draft || plan.isClosed() || plan.isStopped() || plan.isCanceled()) {
            throw new ApiException(ErrorCode.CONFLICT, "仅未关闭、未中止的草稿生产计划可修改附件");
        }
    }

    private static boolean has(AuthUser user, String authority) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(authority));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在"); }
}
