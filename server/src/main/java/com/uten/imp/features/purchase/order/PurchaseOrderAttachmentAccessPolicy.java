package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
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
public class PurchaseOrderAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "PURCHASE_ORDER";
    private final EntityManager em;
    private final PurchaseDocumentAccessPolicy access;
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
        var guard = mutations.order("PURCHASE", ownerId);
        PurchaseOrder locked = em.find(PurchaseOrder.class, ownerId, LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) throw missing();
        em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
        editable(locked, user);
        guard.verifyUnchanged();
    }

    private PurchaseOrder order(UUID id) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定采购订货单");
        PurchaseOrder order = em.find(PurchaseOrder.class, id);
        if (order == null || order.isDeleted()) throw missing();
        return order;
    }

    private void readable(PurchaseOrder order, AuthUser user) {
        if (order.isDeleted()) throw missing();
        boolean visibleOrder = has(user, "purchase_order:view") && access.canRead(order.getMakerId());
        boolean pendingReview = !visibleOrder && has(user, "finance_order_approval:view")
                && approvals.canCurrentActorReviewPending("PURCHASE", order.getId());
        if (!visibleOrder && !pendingReview) throw missing();
        if (!prices.canViewPurchaseOrder()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "采购合同原件包含商业金额，需要订货价格查看权限");
        }
    }

    private void editable(PurchaseOrder order, AuthUser user) {
        readable(order, user);
        if (!has(user, "purchase_order:edit")) throw new ApiException(ErrorCode.FORBIDDEN, "缺少采购订货编辑权限");
        access.requireWritable(order.getMakerId(), "无权修改该采购订货单附件");
        if (order.getStatus() != 0 || order.isClosed()) {
            throw new ApiException(ErrorCode.CONFLICT, "仅未关闭的草稿采购订单可修改附件");
        }
        approvals.requireMutable("PURCHASE", order.getId());
    }

    private static boolean has(AuthUser user, String authority) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(authority));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在"); }
}
