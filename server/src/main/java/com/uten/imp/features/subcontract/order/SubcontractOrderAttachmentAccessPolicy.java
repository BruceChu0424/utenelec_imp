package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CommercialPriceVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/** Uses the original order scope and its pending finance-review visibility exception. */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class SubcontractOrderAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "SUBCONTRACT_ORDER";
    private final EntityManager em;
    private final SubcontractDocumentAccessPolicy access;
    private final CommercialPriceVisibility prices;
    private final ProcurementApprovalProjectionQuery approvals;
    private final ProcurementMutationLocks mutations;

    @Override public String ownerType() { return OWNER_TYPE; }

    @Override public void requireCanView(UUID ownerId, AuthUser user) {
        readable(order(ownerId), user);
    }

    @Override public void requireCanManage(UUID ownerId, AuthUser user) {
        editable(order(ownerId), user);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        editable(order(ownerId), user);
        var guard = mutations.order("SUBCONTRACT", ownerId);
        SubcontractOrder locked = em.find(SubcontractOrder.class, ownerId, LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) throw missing();
        em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
        editable(locked, user);
        guard.verifyUnchanged();
    }

    private SubcontractOrder order(UUID id) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定委外订货单");
        SubcontractOrder order = em.find(SubcontractOrder.class, id);
        if (order == null || order.isDeleted()) throw missing();
        return order;
    }

    private void readable(SubcontractOrder order, AuthUser user) {
        if (order.isDeleted()) throw missing();
        boolean visibleOrder = has(user, "subcontract_order:view") && access.canRead(order.getMakerId());
        boolean pendingReview = !visibleOrder && has(user, "finance_order_approval:view")
                && approvals.canCurrentActorReviewPending("SUBCONTRACT", order.getId());
        if (!visibleOrder && !pendingReview) throw missing();
        if (!prices.canViewSubcontractOrder()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "委外合同原件包含商业金额，需要订货价格查看权限");
        }
    }

    private void editable(SubcontractOrder order, AuthUser user) {
        readable(order, user);
        if (!has(user, "subcontract_order:edit")) throw new ApiException(ErrorCode.FORBIDDEN, "缺少委外订货编辑权限");
        access.requireWritable(order.getMakerId(), "无权修改该委外订货单附件");
        if (order.getStatus() != 0 || order.isClosed()) {
            throw new ApiException(ErrorCode.CONFLICT, "仅未关闭的草稿委外订单可修改附件");
        }
        approvals.requireMutable("SUBCONTRACT", order.getId());
    }

    private static boolean has(AuthUser user, String authority) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(authority));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "委外订货单不存在"); }
}
