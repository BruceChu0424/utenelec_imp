package com.uten.imp.features.stock;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * 库存成本字段可见性。
 *
 * <p>库存余额金额、流水金额和即时库存成本均可直接或间接反推出货品成本，
 * 因此统一复用 {@code goods:cost:view}，不能只按 {@code stock:view} 返回。
 * 未认证或权限解析不到当前用户时一律 fail closed。
 */
@Component
@RequiredArgsConstructor
public class StockCostMasker {

    public static final String PERMISSION = "goods:cost:view";

    private final SecurityContextCurrentUser currentUser;

    public boolean canView() {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(permissions -> permissions.contains(PERMISSION))
                .orElse(false);
    }
}
