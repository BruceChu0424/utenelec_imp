package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Arrays;
import java.util.Set;
import java.util.stream.Collectors;

/** Runtime authority checks for field-sensitive mixed update commands. */
public final class CurrentAuthorityGuard {

    private CurrentAuthorityGuard() {
    }

    /**
     * Requires every authority. Super administrators remain an explicit
     * bypass even if a test principal does not contain the full catalog.
     */
    public static void requireAll(String... authorities) {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication == null || !authentication.isAuthenticated()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前登录状态无效");
        }
        if (authentication.getPrincipal() instanceof AuthUser user && user.isSuperAdmin()) {
            return;
        }
        Set<String> granted = authentication.getAuthorities().stream()
                .map(authority -> authority.getAuthority())
                .collect(Collectors.toSet());
        String missing = Arrays.stream(authorities)
                .filter(authority -> !granted.contains(authority))
                .collect(Collectors.joining("、"));
        if (!missing.isEmpty()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少操作权限：" + missing);
        }
    }
}
