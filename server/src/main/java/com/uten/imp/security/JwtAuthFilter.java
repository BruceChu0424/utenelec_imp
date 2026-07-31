package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.visitor.VisitorAccountRepository;
import io.jsonwebtoken.Claims;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 解析 Authorization: Bearer access-jwt，按 typ claim 区分主体并**逐请求复查 DB 状态**
 * （每请求恰好 1 次主键级闭投影查询，只取状态列，不抓实体图）：
 * <ul>
 *   <li>staff：status != active（含管理员手动锁 locked / 停用 disabled）或软删 → 401；
 *       mcp 以 DB 为准（管理员重置后立即降权）</li>
 *   <li>staff super-admin：以 DB 的 users.is_super_admin 为准（不依赖 JWT claim，重置后立即同步）</li>
 *   <li>visitor：status != active（blocked）→ 401</li>
 * </ul>
 * 状态拒绝时直接写 401 ApiError（前端 session_event_bus 靠 401 触发登出）；
 * token 解析失败（过期/伪造）维持原路径：清上下文，由下游授权链处理。
 */
@Component
@RequiredArgsConstructor
public class JwtAuthFilter extends OncePerRequestFilter {

    private final JwtService jwtService;
    private final UserAccountRepository userRepo;
    private final VisitorAccountRepository visitorRepo;
    private final ObjectMapper objectMapper;
    private final AuditService auditService;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {

        String header = request.getHeader("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            String token = header.substring(7);
            AuthUser authUser;
            try {
                Claims c = jwtService.parse(token);
                String typ = c.get("typ", String.class);
                UUID subjectId = UUID.fromString(c.getSubject());

                authUser = "visitor".equals(typ)
                        ? resolveVisitor(subjectId, c)
                        : resolveStaff(subjectId, c);
            } catch (Exception ex) {
                SecurityContextHolder.clearContext();
                chain.doFilter(request, response);
                return;
            }
            if (authUser == null) {
                // Keep this branch outside the token-parsing catch. A response-serialization
                // failure must never fall through to the protected endpoint.
                SecurityContextHolder.clearContext();
                try {
                    auditService.logSecurityEvent(
                            request, null, null,
                            "access_denied", "account_state_changed", 401);
                } catch (RuntimeException ignored) {
                    // The authentication rejection must remain fail-closed even if the audit sink is down.
                }
                writeUnauthorized(response);
                return;
            }
            UsernamePasswordAuthenticationToken auth =
                    new UsernamePasswordAuthenticationToken(authUser, null, authUser.getAuthorities());
            SecurityContextHolder.getContext().setAuthentication(auth);
            AuditRequestContext.bindVerifiedActor(
                    request,
                    authUser.getId(),
                    authUser.getLoginAccount());
        }
        chain.doFilter(request, response);
    }

    /**
     * 员工：复查 users 状态（status != active 或软删 → 拒绝；mcp 以 DB 为准）。
     * 超级管理员（users.is_super_admin=TRUE）也以 DB 为准：万一被管理员取消超管，
     * 下一次请求立即拿不到 superAdmin 标记。
     */
    private AuthUser resolveStaff(UUID userId, Claims c) {
        UserAccountRepository.AccountState user = userRepo.findAccountStateById(userId).orElse(null);
        if (user == null || user.isDeleted() || !"active".equals(user.getStatus())) {
            return null;
        }
        Long tokenAuthVersion = numericClaim(c, "av");
        Long tokenAuthorizationEpoch = numericClaim(c, "ae");
        if (tokenAuthVersion == null
                || tokenAuthorizationEpoch == null
                || tokenAuthVersion != user.getAuthVersion()
                || tokenAuthorizationEpoch != user.getAuthorizationEpoch()) {
            return null;
        }
        UUID employeeId = c.get("emp", String.class) == null ? null
                : UUID.fromString(c.get("emp", String.class));
        String loginAccount = c.get("acc", String.class);
        Set<String> roles = new HashSet<>(asStringList(c.get("roles")));
        Set<String> perms = new HashSet<>(asStringList(c.get("perms")));
        boolean mcp = user.isMustChangePassword();
        return new AuthUser(userId, employeeId, loginAccount, roles, perms, mcp, true, user.isSuperAdmin());
    }

    /** 访客：复查 visitor_accounts 状态（status != active，如 blocked → 拒绝）。 */
    private AuthUser resolveVisitor(UUID visitorId, Claims c) {
        VisitorAccountRepository.AccountState va = visitorRepo.findAccountStateById(visitorId).orElse(null);
        if (va == null || !"active".equals(va.getStatus())) {
            return null;
        }
        String visitorAccount = c.get("acc", String.class);
        String visitorNo = c.get("vno", String.class);
        Set<String> perms = new HashSet<>(asStringList(c.get("perms")));
        return AuthUser.visitor(visitorId, visitorAccount, visitorNo, perms);
    }

    /** 401 + 统一错误体（对齐 GlobalExceptionHandler 的 ApiError 形状）。 */
    private void writeUnauthorized(HttpServletResponse response) throws IOException {
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        // Build a JSON tree so this fail-closed path does not depend on optional Java-time
        // ObjectMapper modules. This also keeps the canonical ApiError wire shape.
        var body = objectMapper.createObjectNode()
                .put("timestamp", OffsetDateTime.now().toString())
                .put("status", ErrorCode.UNAUTHORIZED.getHttpStatus())
                .put("code", ErrorCode.UNAUTHORIZED.name())
                .put("message", "账号状态或权限已变更，请重新登录");
        response.getWriter().write(objectMapper.writeValueAsString(body));
    }

    private Long numericClaim(Claims claims, String name) {
        Object value = claims.get(name);
        return value instanceof Number number ? number.longValue() : null;
    }

    @SuppressWarnings("unchecked")
    private List<String> asStringList(Object o) {
        return o instanceof List<?> l ? (List<String>) l : List.of();
    }
}
