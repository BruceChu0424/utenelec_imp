package com.uten.imp.features.admin;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** The model can only request a preview. Every candidate and confirmation label comes from the server. */
@Component
@RequiredArgsConstructor
public class AiPermissionGrantTool implements AiChatToolPort {
    private final SecurityContextCurrentUser current;
    private final AiChatAccessPolicy access;
    private final JdbcTemplate jdbc;
    private final PermissionRepository permissions;
    private final UserAccountRepository accounts;
    private final AiPermissionProposalCodec codec;

    @Override public String name() { return "prepare_permission_grant"; }
    @Override public String title() { return "准备员工授权"; }
    @Override public String description() { return "按员工姓名或工号及一项权限名称或权限码，查询真实候选并准备个人加授确认卡。只准备，不执行授权。重名或多项权限需用户明确选择。"; }
    @Override public String domain() { return "ADMIN"; }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("employeeKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 100),
                        "permissionKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 100)),
                "required", List.of("employeeKeyword", "permissionKeyword"));
    }
    @Override public boolean available() {
        return codec.available() && access.hasDomain(domain()) && current.get().filter(AiPermissionGrantTool::allowed).isPresent();
    }
    static boolean allowed(AuthUser actor) {
        return !actor.isVisitor() && actor.isSuperAdmin() && actor.getImpersonatedBy() == null
                && actor.getPermissions().contains("authorization:manage") && actor.getPermissions().contains("ai:use");
    }

    @Override
    @Transactional(readOnly = true)
    public Map<String, Object> execute(Map<String, Object> arguments) {
        access.requireDomain(domain());
        AuthUser actor = current.get().filter(AiPermissionGrantTool::allowed)
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "仅超级管理员可通过对话准备授权"));
        if (arguments == null || !arguments.keySet().equals(Set.of("employeeKeyword", "permissionKeyword"))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "授权请求只能包含员工和一项具体权限");
        }
        String employee = keyword(arguments, "employeeKeyword");
        String permission = keyword(arguments, "permissionKeyword");
        var actorState = accounts.findAccountStateById(actor.getId()).orElseThrow(AiPermissionGrantTool::changed);
        if (!actorState.isSuperAdmin() || actorState.isDeleted() || !"active".equals(actorState.getStatus())) throw changed();
        List<Candidate> candidates = jdbc.query("""
                SELECT u.id, u.auth_version, e.code, e.full_name, d.name AS department
                FROM users u JOIN employees e ON e.id=u.employee_id
                JOIN departments d ON d.id=e.department_id AND d.is_deleted=FALSE
                WHERE u.is_deleted=FALSE AND u.status='active' AND u.is_super_admin=FALSE AND u.id<>?
                  AND e.is_deleted=FALSE AND e.status IN ('active','probation','onLeave')
                  AND (lower(e.code) LIKE lower(?) ESCAPE '!' OR lower(e.full_name) LIKE lower(?) ESCAPE '!')
                ORDER BY CASE WHEN lower(e.code)=lower(?) THEN 0 ELSE 1 END,e.code,u.id LIMIT 11
                """, (rs, row) -> new Candidate(rs.getObject("id", UUID.class), rs.getLong("auth_version"),
                rs.getString("code"), rs.getString("full_name"), rs.getString("department")),
                actor.getId(), pattern(employee), pattern(employee), employee);
        List<Candidate> exact = candidates.stream().filter(c -> c.code().equalsIgnoreCase(employee)).toList();
        if (!exact.isEmpty()) candidates = exact;
        if (candidates.isEmpty()) return reply("没有找到可授权的在职员工账号。请提供准确工号；不能修改本人或超级管理员的授权。");
        if (candidates.size() != 1) return reply("找到多位员工，请明确工号后再发起：\n" + candidates.stream().limit(10)
                .map(c -> c.code() + " · " + c.name() + " · " + c.department()).collect(Collectors.joining("\n")));
        List<Permission> matches = permissions.findByCode(permission).map(List::of).orElseGet(() ->
                permissions.findAll().stream().filter(p -> p.getName().contains(permission) || p.getCode().contains(permission)).limit(11).toList());
        if (matches.isEmpty()) return reply("权限目录中没有找到这项权限，请提供具体页面及动作，例如查看、编辑、审批。");
        if (matches.size() != 1) return reply("匹配到多项权限，请明确一项权限码后再发起：\n" + matches.stream().limit(10)
                .map(p -> p.getName() + "(" + p.getCode() + ")").collect(Collectors.joining("\n")));
        Permission selected = matches.getFirst();
        if (!GrantPolicy.individuallyGrantable(selected.grantPolicies())) {
            return reply("这项权限只随超级管理员身份生效，不能单独授予。");
        }
        Candidate target = candidates.getFirst();
        Instant now = Instant.now();
        String token = codec.encode(new AiPermissionProposalCodec.Proposal(actor.getId(), actorState.getAuthVersion(),
                actorState.getAuthorizationEpoch(), target.id(), target.authVersion(), selected.getId(), selected.getCode(),
                now.getEpochSecond(), now.plusSeconds(600).getEpochSecond()));
        String targetLabel = target.name() + "(" + target.code() + "，" + target.department() + ")";
        String scope = "仅增加这一项个人权限；其他个人授权和数据范围保持不变。"
                + (selected.getDescription() == null || selected.getDescription().isBlank() ? "" : "\n" + selected.getDescription());
        return Map.of("reply", "已准备授权确认，请核对员工和具体权限。确认并重新认证后才会生效。",
                "actions", List.of(Map.of("type", "CONFIRM_PERMISSION_GRANT", "proposalId", token,
                        "title", "确认授予权限", "summary", "为 " + targetLabel + " 授予 " + selected.getName(),
                        "targetName", targetLabel, "permissionCode", selected.getCode(), "permissionName", selected.getName(),
                        "scopeSummary", scope, "expiresAt", now.plusSeconds(600).toString())));
    }

    private record Candidate(UUID id, long authVersion, String code, String name, String department) {}
    private static Map<String, Object> reply(String value) { return Map.of("reply", value); }
    private static String keyword(Map<String, Object> args, String key) {
        Object raw = args == null ? null : args.get(key);
        if (!(raw instanceof String value) || value.isBlank() || value.length() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请提供明确的员工和权限名称");
        }
        return value.strip();
    }
    private static String pattern(String value) { return "%" + value.replace("!", "!!").replace("%", "!%").replace("_", "!_") + "%"; }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN, "账号授权状态已变化，请重新登录"); }
}
