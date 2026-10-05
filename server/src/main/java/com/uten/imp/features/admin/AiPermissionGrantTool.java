package com.uten.imp.features.admin;

import com.uten.imp.application.port.AiChatActionProposalPort;
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

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * The model can only request a preview. Every candidate and confirmation line comes from the server and
 * becomes a one-time ADR-150 confirmation card; the grant itself runs on the step-up endpoint.
 */
@Component
@RequiredArgsConstructor
public class AiPermissionGrantTool implements AiChatToolPort {
    private final SecurityContextCurrentUser current;
    private final AiChatAccessPolicy access;
    private final JdbcTemplate jdbc;
    private final PermissionRepository permissions;
    private final UserAccountRepository accounts;
    private final AiChatActionProposalPort proposals;

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
    /** Grant wording in the super admin's own message (page text such as a notice body never counts). */
    private static final java.util.regex.Pattern GRANT_INTENT = java.util.regex.Pattern.compile(
            "开通|授予|授权|赋予|赋权|加.{0,8}权限|分配.{0,8}权限|开.{0,4}权限|给.{0,16}权限"
                    + "|(?i:\\b(?:grant|permission|permissions|authorize|access)\\b)");
    @Override public boolean requestedBy(String userMessage) { return grantRequested(userMessage); }
    public static boolean grantRequested(String userMessage) {
        return userMessage != null && userMessage.length() <= 2000 && GRANT_INTENT.matcher(
                java.text.Normalizer.normalize(userMessage, java.text.Normalizer.Form.NFKC)).find();
    }
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get().filter(AiPermissionGrantTool::allowed).isPresent();
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
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "暂时不能办理这项授权"));
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
        if (candidates.isEmpty()) return reply("没找到可授权的员工，请核对工号。");
        if (candidates.size() != 1) return choices("找到多位员工，请明确工号：", candidates.stream().limit(10)
                .map(c -> c.code() + " · " + c.name() + " · " + c.department()).toList());
        List<Permission> matches = permissions.findByCode(permission).map(List::of).orElseGet(() ->
                permissions.findAll().stream().filter(p -> p.getName().contains(permission) || p.getCode().contains(permission)).limit(11).toList());
        if (matches.isEmpty()) return reply("没找到这项授权，请说清页面和操作，例如“查看销售订单”。");
        if (matches.size() != 1) return choices("找到多项操作，请选一项：", matches.stream().limit(10)
                .map(p -> p.getName() + (p.getCategory() == null ? "" : " · " + p.getCategory())).toList());
        Permission selected = matches.getFirst();
        if (!GrantPolicy.individuallyGrantable(selected.grantPolicies())) {
            return reply("这项不能单独授权。");
        }
        Candidate target = candidates.getFirst();
        String targetLabel = target.name() + "(" + target.code() + ", " + target.department() + ")";
        List<String> lines = new java.util.ArrayList<>(List.of("员工: " + targetLabel, "授予: " + selected.getName()
                + (selected.getCategory() == null ? "" : " (" + selected.getCategory() + ")"), "只增加这一项授权，其它授权不变。"));
        if (selected.getDescription() != null && !selected.getDescription().isBlank())
            lines.add("说明: " + truncate(selected.getDescription().strip(), 200));
        Map<String, Object> card = proposals.propose(new AiChatActionProposalPort.Draft(
                AiChatActionProposalPort.PERMISSION_GRANT, AiChatActionProposalPort.PERMISSION_GRANT, "SERVER",
                "确认授予权限", List.copyOf(lines), "HIGH", "确认前要再输入一次登录密码；授权立即生效并记入审计。", true,
                null, "USER", target.id().toString(), target.authVersion(),
                Map.of("permissionId", selected.getId().toString(), "permissionCode", selected.getCode()), null));
        return Map.of("reply", "请核对员工和授权项。点确认并验证身份后才会生效。", "actions", List.of(card));
    }

    private record Candidate(UUID id, long authVersion, String code, String name, String department) {}
    private static Map<String, Object> choices(String heading, List<String> values) {
        return Map.of("reply", heading + "\n" + values.stream().limit(5).collect(Collectors.joining("\n")),
                "detailReply", heading + "\n" + String.join("\n", values));
    }
    private static Map<String, Object> reply(String value) { return Map.of("reply", value); }
    private static String keyword(Map<String, Object> args, String key) {
        Object raw = args == null ? null : args.get(key);
        if (!(raw instanceof String value) || value.isBlank() || value.length() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请提供明确的员工和权限名称");
        }
        return value.strip();
    }
    private static String truncate(String value, int max) { return value.length() <= max ? value : value.substring(0, max); }
    private static String pattern(String value) { return "%" + value.replace("!", "!!").replace("%", "!%").replace("_", "!_") + "%"; }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN, "账号状态有变化，请重新登录"); }
}
