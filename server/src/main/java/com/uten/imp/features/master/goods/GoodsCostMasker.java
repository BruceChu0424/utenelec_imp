package com.uten.imp.features.master.goods;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * 货品成本可见性判定（沿用 {@code employee:pii:view} / {@code sales_order:price:view}
 * 按权限点脱敏机制）。
 *
 * <p>权限点 {@code goods:cost:view}（种子，默认仅财务部 DEPT_FIN；超管恒有全量权限）。
 * 未授予的角色看货品详情时，18 个成本字段一律不返回（null + costMasked=true），
 * 前端据此隐藏「成本预算」Tab。
 */
@Component
@RequiredArgsConstructor
public class GoodsCostMasker {

    public static final String PERM = "goods:cost:view";

    private final SecurityContextCurrentUser currentUser;

    /** 当前用户是否可看货品成本。 */
    public boolean canView() {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(p -> p.contains(PERM))
                .orElse(false);
    }
}
