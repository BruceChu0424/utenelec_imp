package com.uten.imp.security;

import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.UUID;

/** 从 SecurityContext 取当前登录用户。 */
@Component
public class SecurityContextCurrentUser {

    public Optional<AuthUser> get() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !auth.isAuthenticated() || !(auth.getPrincipal() instanceof AuthUser user)) {
            return Optional.empty();
        }
        return Optional.of(user);
    }

    public Optional<UUID> id() {
        return get().map(AuthUser::getId);
    }

    /** 必须登录，否则抛 IllegalStateException（用于只应在已认证上下文调用的地方）。 */
    public UUID requireId() {
        return id().orElseThrow(() -> new IllegalStateException("当前无登录用户"));
    }

    /** 当前登录用户的员工档案 ID（employees.id）。制单员/审核员等业务人名字段统一存它——报表按 employees.id JOIN 姓名。 */
    public Optional<UUID> employeeId() {
        return get().map(AuthUser::getEmployeeId);
    }

    /** 必须为员工账号（staff 且已绑员工档案），否则抛 IllegalStateException。 */
    public UUID requireEmployeeId() {
        return employeeId().orElseThrow(() -> new IllegalStateException("当前账号未绑定员工档案"));
    }
}
