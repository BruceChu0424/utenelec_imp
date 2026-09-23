package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.Set;

/**
 * 谁能给某个账号发放登录凭据 (重置临时密码、给存量员工补开账号) 的唯一判定 (ADR-110; security-02)。
 *
 * <p>发放凭据的人会看到明文临时密码, 等于能以目标身份登录。目标 (按开号/重置后的有效权限: 部门授权、
 * 个人授权与委派) 持有任一「高危权限」时只有超级管理员能发放, 否则账号支持人员可以借此冒充付款审批人、
 * 工资审核人等, 绕过职责分离。高危清单是权限目录上的 {@code permissions.high_risk} 标记, 在迁移里集中
 * 维护 (资金/工资/报销的审批、付款、过账、冲销, 审计查看, 授权管理, 库存与账户余额调整, 账号支持本身),
 * 不在代码里手写。</p>
 */
@Component
public class CredentialIssuancePolicy {

    private final NamedParameterJdbcTemplate jdbc;
    private final PermissionResolver permissionResolver;
    private final SecurityContextCurrentUser currentUser;

    public CredentialIssuancePolicy(NamedParameterJdbcTemplate jdbc,
                                    PermissionResolver permissionResolver,
                                    SecurityContextCurrentUser currentUser) {
        this.jdbc = jdbc;
        this.permissionResolver = permissionResolver;
        this.currentUser = currentUser;
    }

    /** 当前操作人不是超管且目标持有高危权限时拒绝 (403)。 */
    public void requireCanIssueCredentials(UserAccount target) {
        AuthUser actor = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (actor.isSuperAdmin()) {
            return;
        }
        if (holdsHighRiskPermission(permissionResolver.permsOf(target))) {
            throw new ApiException(ErrorCode.FORBIDDEN,
                    "该员工持有审批、付款、审计或授权等高危权限，只有超级管理员能为其重置密码或开通账号");
        }
    }

    boolean holdsHighRiskPermission(Set<String> held) {
        if (held == null || held.isEmpty()) {
            return false;
        }
        Boolean hit = jdbc.queryForObject(
                "SELECT EXISTS (SELECT 1 FROM permissions WHERE high_risk AND code IN (:held))",
                new MapSqlParameterSource("held", held),
                Boolean.class);
        return Boolean.TRUE.equals(hit);
    }
}
