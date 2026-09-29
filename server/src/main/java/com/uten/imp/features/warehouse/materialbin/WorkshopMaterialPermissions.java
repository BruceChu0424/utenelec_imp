package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

import java.util.Set;

/**
 * 车间内料仓的 7 个权限码 (ADR-131 §8.2) 与"按钮显隐"判定。
 *
 * <p>页面按钮只看服务端随数据返回的 {@code allowedActions}; 这里按当前主体的权限码算好,
 * 页面不直接写权限码 (页面权限字面量基线只许下降)。接口本身的放行仍以控制器上的
 * {@code @PreAuthorize} 为准。
 */
@Component
public class WorkshopMaterialPermissions {

    public static final String VIEW = "workshop_material:view";
    public static final String ISSUE = "workshop_material:issue";
    public static final String REQUEST = "workshop_material:request";
    public static final String COUNT = "workshop_material:count";
    public static final String CHOOSE = "workshop_material:choose";
    public static final String SETUP = "workshop_material:setup";
    public static final String REOPEN = "workshop_material:reopen";

    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialPermissions(SecurityContextCurrentUser currentUser) {
        this.currentUser = currentUser;
    }

    /** 当前主体是否持有该码 (超管视为全部持有)。 */
    public boolean has(String code) {
        return currentUser.get().map(user -> holds(user, code)).orElse(false);
    }

    static boolean holds(AuthUser user, String code) {
        if (user == null) return false;
        if (user.isSuperAdmin()) return true;
        Set<String> permissions = user.getPermissions();
        return permissions != null && permissions.contains(code);
    }
}
