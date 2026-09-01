package com.uten.imp.features.purchase.receipt;

import com.uten.imp.security.CommercialPriceVisibility;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * 收货单价格脱敏判定（V302，沿用 V90 sales_order:price:view 按权限点脱敏机制）。
 *
 * <p>权限点 {@code purchase_receipt:price:view} / {@code subcontract_receipt:price:view}
 * 决定采购/委外业务页面的商业字段可见性。历史 V302 曾把权限授给 PMC 父部门，
 * 因祖先继承可能覆盖仓储等子部门；因此仓库模块不得把本判定当作页面隔离手段，
 * 必须使用结构上不含商业字段的 warehouse history projection。对没有该权限的业务页
 * 调用者，服务端仍把币税结算、单价和金额族置 null，前端掩码只负责呈现。
 */
@Component
@RequiredArgsConstructor
public class ReceiptPriceMasker {

    public static final String PURCHASE_PERM = CommercialPriceVisibility.PURCHASE_PERMISSION;
    public static final String SUBCONTRACT_PERM =
            CommercialPriceVisibility.SUBCONTRACT_RECEIPT_PERMISSION;

    private final CommercialPriceVisibility visibility;

    /** 当前用户是否可看采购收货单价格。 */
    public boolean canViewPurchaseReceipt() {
        return visibility.canViewPurchaseReceipt();
    }

    /** Receipt-only compatibility alias; other purchase pages must not use it. */
    @Deprecated(forRemoval = false)
    public boolean canViewPurchase() {
        return canViewPurchaseReceipt();
    }

    /** 当前用户是否可看委外进仓单价格。 */
    public boolean canViewSubcontractReceipt() {
        return visibility.canViewSubcontractReceipt();
    }

    /** Receipt-only compatibility alias; other subcontract pages must not use it. */
    @Deprecated(forRemoval = false)
    public boolean canViewSubcontract() {
        return canViewSubcontractReceipt();
    }
}
