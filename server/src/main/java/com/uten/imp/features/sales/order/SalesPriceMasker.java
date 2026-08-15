package com.uten.imp.features.sales.order;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * 订单价格脱敏判定（SOP §三8，沿用 `employee:pii:view` 按权限点脱敏机制）。
 *
 * <p>权限点 {@code sales_order:price:view}（种子，默认仅综合营销部；超管恒有全量权限）。
 * 未授予的角色（生产/仓库/PMC 等）看订单列表/详情/报表/导出时价格列一律打码（null 返回 +
 * priceMasked 标记，前端渲染 ***）。
 */
@Component
@RequiredArgsConstructor
public class SalesPriceMasker {

    public static final String PERM = "sales_order:price:view";

    private final SecurityContextCurrentUser currentUser;

    /** 当前用户是否可看订单价格。 */
    public boolean canView() {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(p -> p.contains(PERM))
                .orElse(false);
    }
}
