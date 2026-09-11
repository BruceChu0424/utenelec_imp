package com.uten.imp.features.sales.order;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesMutationFootprintService;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/** Original contracts cannot be redacted like the order's monetary DTO fields. */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class SalesOrderAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "SALES_ORDER";
    private final EntityManager em;
    private final SalesDocumentAccessPolicy access;
    private final SalesPriceMasker prices;
    private final SalesMutationFootprintService mutations;
    private final TaskClaimMutationGuardPort claims;

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
        mutations.lockOrder(ownerId, List.of());
        SalesOrder locked = em.find(SalesOrder.class, ownerId, LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) throw missing();
        em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
        editable(locked, user);
        claims.requireNoActiveClaim("SALES_ORDER_FINANCE_CONFIRM", ownerId.toString());
    }

    private SalesOrder order(UUID id) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定销售订货单");
        SalesOrder order = em.find(SalesOrder.class, id);
        if (order == null || order.isDeleted()) throw missing();
        return order;
    }

    private void readable(SalesOrder order, AuthUser user) {
        // 财务确认视角（2026-09-09，2026-09-10 收紧）：持 sales_order_finance:view 的财务
        // 只对「已进入财务流程」的订单（已提交待确认 / 已退回 / 已确认）读附件，不要求
        // 销售文档权限与对象归属——财务确认队列本身即全量可读口径，审核页已展示同等的
        // 金额事实。销售草稿尚未提交，财务不得借页面权限提前读取。
        boolean financeView = has(user, "sales_order_finance:view") && enteredFinanceFlow(order);
        if (order.isDeleted()
                || (!financeView && !has(user, "sales_order:view"))) {
            throw missing();
        }
        if (!financeView) {
            access.requireReadable(order.getOwnerEmployeeId(), "销售订货单不存在");
            if (!prices.canView()) {
                throw new ApiException(ErrorCode.FORBIDDEN, "销售合同原件包含商业金额，需要订货价格查看权限");
            }
        }
    }

    /** 已提交待财务确认、财务已退回或财务已确认——三者之外（纯草稿）财务不可读。 */
    static boolean enteredFinanceFlow(SalesOrder order) {
        boolean pending = order.getStatus() != null && order.getStatus() == 1 && !order.isFinanceConfirmed();
        return pending || order.isFinanceRejected() || order.isFinanceConfirmed();
    }

    private void editable(SalesOrder order, AuthUser user) {
        readable(order, user);
        if (!has(user, "sales_order:edit")) throw new ApiException(ErrorCode.FORBIDDEN, "缺少销售订货编辑权限");
        access.requireWritable(order.getOwnerEmployeeId(), "无权修改该销售订货单附件");
        boolean draftOrReturned = order.getStatus() == 0
                || (order.getStatus() == 1 && order.isFinanceRejected() && !order.isFinanceConfirmed());
        if (!draftOrReturned || order.isClosed() || order.isStopped()) {
            throw new ApiException(ErrorCode.CONFLICT, "仅未关闭、未中止的草稿或财务退回销售订单可修改附件");
        }
    }

    private static boolean has(AuthUser user, String authority) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(authority));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在"); }
}
