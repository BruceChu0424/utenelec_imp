package com.uten.imp.features.admin.remoteaccess;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TrustedRequestOriginPolicy;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class RemoteAccessSettingsService {
    private final NamedParameterJdbcTemplate jdbc;
    private final DeploymentProperties deployment;
    private final JwtProperties jwt;
    private final TrustedRequestOriginPolicy origins;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final AuditService audit;

    public record Policy(boolean enabled, int maxUsers, long version) {}
    public record Change(@NotNull Boolean enabled, @NotNull @Min(1) @Max(10000) Integer maxUsers,
                         @NotNull @Min(0) Long expectedVersion) {}
    public record AuthorizedUser(UUID id, String username, String displayName,
                                 boolean mfaEnabled, boolean remoteAccess) {}
    public record Status(Policy policy, List<AuthorizedUser> authorizedUsers, int authorizedCount,
                         boolean remoteChannelConfigured, String currentAccessChannel,
                         OffsetDateTime observedAt, String deploymentId) {}

    /** Used on credential issuance, never as an additional query on every HTTP request. */
    @Transactional(readOnly = true)
    public boolean isEnabled() { return policy(false).enabled(); }

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public Status status() {
        List<AuthorizedUser> users = jdbc.query("""
                SELECT u.id,u.login_account,coalesce(e.full_name,u.login_account) AS display_name,
                       u.remote_access,(m.enabled_at IS NOT NULL) AS mfa_enabled
                FROM users u LEFT JOIN employees e ON e.id=u.employee_id
                LEFT JOIN staff_mfa m ON m.user_id=u.id
                WHERE u.remote_access AND NOT u.is_deleted
                ORDER BY display_name,u.id
                """, Map.of(), (row, index) -> new AuthorizedUser(row.getObject("id",UUID.class),
                row.getString("login_account"), row.getString("display_name"),
                row.getBoolean("mfa_enabled"), row.getBoolean("remote_access")));
        return new Status(policy(false), users, users.size(), deployment.isRemoteIngressEnabled(),
                origins.current() == TrustedRequestOriginPolicy.Origin.REMOTE ? "remote" : "local",
                OffsetDateTime.now(ZoneOffset.UTC),
                UUID.nameUUIDFromBytes(jwt.getIssuer().getBytes(StandardCharsets.UTF_8)).toString());
    }

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public Policy update(Change change) {
        requireLocalAdministrator();
        Policy before = policy(true);
        if (before.version() != change.expectedVersion()) {
            throw new ApiException(ErrorCode.CONFLICT, "外网访问设置已变化，请刷新后重新核对");
        }
        if (change.maxUsers() < authorizedCount()) {
            throw new ApiException(ErrorCode.CONFLICT, "人数上限不能低于当前已授权人数，请先撤销多余授权");
        }
        if (change.enabled() && !deployment.isRemoteIngressEnabled()) {
            throw new ApiException(ErrorCode.CONFLICT, "服务器尚未配置受控外网入口，请先完成入口安装与验收");
        }
        if (before.enabled() == change.enabled() && before.maxUsers() == change.maxUsers()) return before;
        var actor = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        tx.bindActor(actor.getId(), actor.getLoginAccount());
        jdbc.update("""
                UPDATE remote_access_policy SET enabled=:enabled,max_users=:max,
                version=version+1,updated_at=now(),updated_by=:actor WHERE singleton_id=1
                """, new MapSqlParameterSource().addValue("enabled",change.enabled())
                .addValue("max",change.maxUsers()).addValue("actor",actor.getId()));
        audit.logCommitted(actor.getId(),actor.getLoginAccount(),"remote_access_policy_update",
                "remote_access_policy","1","success");
        return policy(false);
    }

    /** Serialize grants with the limit change; must run in the caller's grant transaction. */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void requireGrantCapacity(UUID targetId) {
        requireLocalAdministrator();
        Policy value = policy(true);
        List<Boolean> existing = jdbc.query("SELECT remote_access FROM users WHERE id=:id AND NOT is_deleted",
                Map.of("id",targetId),(row,index) -> row.getBoolean(1));
        if (existing.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND,"账号不存在");
        if (!Boolean.TRUE.equals(existing.getFirst()) && authorizedCount() >= value.maxUsers()) {
            throw new ApiException(ErrorCode.CONFLICT,"已达到外网授权人数上限，请先撤销授权或核定容量后调整上限");
        }
    }

    private int authorizedCount() {
        Integer count = jdbc.queryForObject("SELECT count(*) FROM users WHERE remote_access AND NOT is_deleted",
                Map.of(),Integer.class);
        return count == null ? 0 : count;
    }

    private Policy policy(boolean lock) {
        List<Policy> result = jdbc.query("SELECT enabled,max_users,version FROM remote_access_policy WHERE singleton_id=1"
                + (lock ? " FOR UPDATE" : ""), Map.of(),
                (row,index) -> new Policy(row.getBoolean("enabled"),row.getInt("max_users"),row.getLong("version")));
        if (result.size() != 1) throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE,"暂时无法确认外网访问策略");
        return result.getFirst();
    }

    private void requireLocalAdministrator() {
        if (origins.current() != TrustedRequestOriginPolicy.Origin.LOCAL) {
            throw new ApiException(ErrorCode.FORBIDDEN,"请从公司内部入口管理外网开放和授权容量");
        }
    }
}
