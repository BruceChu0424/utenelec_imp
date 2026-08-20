package com.uten.imp.features.purchase.receipt;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * 收货单价格脱敏判定（V302，沿用 V90 sales_order:price:view 按权限点脱敏机制）。
 *
 * <p>权限点 {@code purchase_receipt:price:view} / {@code subcontract_receipt:price:view}
 * （种子授予 DEPT_PMC/SUB_PURCHASE/DEPT_FIN/GM；超管恒有全量权限）。未授予的角色
 * （仓库/生产等）看收货单列表/详情时价格金额族字段一律置 null + priceMasked 标记，
 * 前端据此渲染 ***。服务端置 null 是脱敏底线，前端掩码只是呈现层。
 */
@Component
@RequiredArgsConstructor
public class ReceiptPriceMasker {

    public static final String PURCHASE_PERM = "purchase_receipt:price:view";
    public static final String SUBCONTRACT_PERM = "subcontract_receipt:price:view";

    private final SecurityContextCurrentUser currentUser;

    /** 当前用户是否可看采购收货单价格。 */
    public boolean canViewPurchase() {
        return canView(PURCHASE_PERM);
    }

    /** 当前用户是否可看委外进仓单价格。 */
    public boolean canViewSubcontract() {
        return canView(SUBCONTRACT_PERM);
    }

    private boolean canView(String perm) {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(p -> p.contains(perm))
                .orElse(false);
    }
}
