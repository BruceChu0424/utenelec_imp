package com.uten.imp.security;

import com.uten.imp.features.auth.PermissionResolver;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

/**
 * 给后台工作(AI 识别任务等)重建提交人的主体(ADR-133)。
 *
 * <p>与 {@link JwtAuthFilter} 的员工解析同一套判定: 从服务端账号状态重建, 不信任任何提交时的副本。
 * 账号不存在、已删除、非 active(锁定/停用)、首登待改密、未绑定员工或登录账号为空, 或者
 * {@code users.auth_version} / {@code authorization_state.epoch} 与提交时记录的不一致, 一律拒绝;
 * 权限经 {@link StaffAuthorityResolver} 按授权戳解析(与请求线程同一缓存口径)。
 * 从不回落到超管或系统身份, 也不保留会话 id(后台任务不能再认证, 也不续期会话)。
 */
@Component
public class SubmitterPrincipalRestorer {

    private final NamedParameterJdbcTemplate jdbc;
    private final StaffAuthorityResolver staffAuthorityResolver;

    public SubmitterPrincipalRestorer(NamedParameterJdbcTemplate jdbc,
                                      StaffAuthorityResolver staffAuthorityResolver) {
        this.jdbc = jdbc;
        this.staffAuthorityResolver = staffAuthorityResolver;
    }

    /** 提交时要记录的授权戳(与 JWT 的 av/ae 声明同口径)。 */
    public record AuthorizationStamps(long authVersion, long authorizationEpoch) {
    }

    /**
     * 读当前账号的授权戳。只在请求线程、账号刚通过 {@link JwtAuthFilter} 校验之后调用;
     * 账号不存在时返回空。
     */
    public Optional<AuthorizationStamps> currentStamps(UUID userId) {
        return load(userId).map(state -> new AuthorizationStamps(state.authVersion(), state.authorizationEpoch()));
    }

    /**
     * 重建提交人主体。
     *
     * @param userId                提交人 users.id
     * @param expectedAuthVersion   提交时的 users.auth_version
     * @param expectedEpoch         提交时的 authorization_state.epoch; 为空视为不一致(失败关闭)
     * @throws PrincipalChangedException 账号状态或授权戳已变化
     */
    public AuthUser restore(UUID userId, long expectedAuthVersion, Long expectedEpoch) {
        Objects.requireNonNull(userId, "userId");
        AccountState state = load(userId).orElseThrow(() -> new PrincipalChangedException("account_missing"));
        if (state.deleted() || !"active".equals(state.status())) {
            throw new PrincipalChangedException("account_inactive");
        }
        if (state.mustChangePassword()) {
            throw new PrincipalChangedException("password_change_required");
        }
        if (state.employeeId() == null || state.loginAccount() == null || state.loginAccount().isBlank()) {
            throw new PrincipalChangedException("employee_unbound");
        }
        if (state.authVersion() != expectedAuthVersion
                || expectedEpoch == null
                || state.authorizationEpoch() != expectedEpoch) {
            throw new PrincipalChangedException("authorization_changed");
        }
        PermissionResolver.AuthorizationSnapshot authorities = staffAuthorityResolver.resolve(
                userId,
                state.employeeId(),
                state.superAdmin(),
                state.authVersion(),
                state.authorizationEpoch());
        return new AuthUser(
                userId,
                state.employeeId(),
                state.loginAccount(),
                authorities.permissions(),
                false,
                true,
                state.superAdmin(),
                state.remoteAccess(),
                null,
                null);
    }

    private Optional<AccountState> load(UUID userId) {
        List<AccountState> rows = jdbc.query("""
                SELECT u.employee_id, u.login_account, u.status, u.must_change_password,
                       u.is_super_admin, u.remote_access, u.is_deleted, u.auth_version,
                       a.epoch AS authorization_epoch
                FROM users u
                CROSS JOIN authorization_state a
                WHERE u.id = :id
                  AND a.singleton_id = 1
                """,
                new MapSqlParameterSource("id", userId),
                (rs, rowNum) -> new AccountState(
                        rs.getObject("employee_id", UUID.class),
                        rs.getString("login_account"),
                        rs.getString("status"),
                        rs.getBoolean("must_change_password"),
                        rs.getBoolean("is_super_admin"),
                        rs.getBoolean("remote_access"),
                        rs.getBoolean("is_deleted"),
                        rs.getLong("auth_version"),
                        rs.getLong("authorization_epoch")));
        return rows.stream().findFirst();
    }

    private record AccountState(
            UUID employeeId,
            String loginAccount,
            String status,
            boolean mustChangePassword,
            boolean superAdmin,
            boolean remoteAccess,
            boolean deleted,
            long authVersion,
            long authorizationEpoch) {
    }

    /** 提交人账号状态或权限已变化; {@link #reason()} 只用于服务端日志, 不给用户看。 */
    public static final class PrincipalChangedException extends RuntimeException {
        private final String reason;

        public PrincipalChangedException(String reason) {
            super("submitter principal changed: " + reason);
            this.reason = reason;
        }

        public String reason() {
            return reason;
        }
    }
}
