package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.auth.PermissionResolver;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.ExpiredJwtException;
import io.jsonwebtoken.JwtException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/**
 * Parses bearer access tokens and rebuilds the current principal from server-side
 * account, authorization and session state.
 *
 * <p>One SQL statement per request reads the account projection together with the
 * server-side session named by the token {@code sid} (ADR-110): a revoked session,
 * an idle session (longer than {@code session_idle_timeout_minutes} since the last
 * human request) or a session past its absolute lifetime is a 401. Human requests
 * refresh {@code last_seen_at} at most once per minute; requests the client sends
 * while its user is idle (polling, timed refreshes, heartbeats; declared by the
 * {@link AutomaticRequestPolicy#HEADER} header) never extend a session.
 *
 * <p>Malformed, expired or explicitly invalidated credentials remain authentication
 * failures. Database and authority-resolution failures are availability failures and
 * return a structured 503 so clients keep the session and can retry.
 */
@Component
@RequiredArgsConstructor
@Slf4j
public class JwtAuthFilter extends OncePerRequestFilter {

    private static final Set<String> PUBLIC_STAFF_AUTH_PATHS = Set.of(
            "/api/auth/login",
            "/api/auth/refresh",
            "/api/auth/logout");
    private static final String SERVICE_UNAVAILABLE_CODE = "SERVICE_UNAVAILABLE";
    private static final String SERVICE_UNAVAILABLE_MESSAGE = "认证服务暂不可用，请稍后重试";

    private final JwtService jwtService;
    private final AuthSessionService sessions;
    private final StaffAuthorityResolver staffAuthorityResolver;
    private final ObjectMapper objectMapper;
    private final AuditService auditService;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {

        String header = request.getHeader("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            String token = header.substring(7);
            Claims claims;
            String tokenType;
            UUID subjectId;
            UUID sessionId;
            try {
                claims = jwtService.parse(token);
                tokenType = requiredTokenType(claims);
                subjectId = requiredSubjectId(claims);
                sessionId = optionalSessionId(claims);
            } catch (JwtException | IllegalArgumentException ex) {
                // 签名正确只是过期: 例行的「该刷新令牌了」, 审计不记这次 401(ADR-105)。
                if (ex instanceof ExpiredJwtException) {
                    AuditRequestContext.markExpiredToken(request);
                }
                SecurityContextHolder.clearContext();
                chain.doFilter(request, response);
                return;
            }

            Resolution resolution;
            try {
                boolean automatic = AutomaticRequestPolicy.isAutomatic(request);
                resolution = sessionId == null
                        ? Resolution.rejected("session_missing")
                        : switch (tokenType) {
                            case "staff" -> resolveStaff(subjectId, sessionId, claims, automatic);
                            case "visitor" -> resolveVisitor(subjectId, sessionId, claims, automatic);
                            default -> Resolution.rejected("account_state_changed");
                        };
            } catch (RuntimeException ex) {
                // Account and permission state is server-side. An unavailable database
                // or broken resolver is not evidence that the caller's token is invalid.
                SecurityContextHolder.clearContext();
                log.error(
                        "Authentication state resolution failed for {} {}",
                        request.getMethod(),
                        request.getRequestURI(),
                        ex);
                writeServiceUnavailable(response);
                return;
            }
            AuthUser authUser = resolution.user();
            if (authUser == null) {
                // Keep this branch outside the token-parsing catch. A response-serialization
                // failure must never fall through to the protected endpoint.
                SecurityContextHolder.clearContext();
                try {
                    auditService.logSecurityEvent(
                            request, null, null,
                            "access_denied", resolution.reason(), 401);
                } catch (RuntimeException ignored) {
                    // Authentication rejection must remain fail-closed if the audit sink is down.
                }
                writeUnauthorized(response, resolution.reason());
                return;
            }
            UsernamePasswordAuthenticationToken auth =
                    new UsernamePasswordAuthenticationToken(authUser, null, authUser.getAuthorities());
            SecurityContextHolder.getContext().setAuthentication(auth);
            // 模拟身份时把请求内全部审计的真实操作人绑成 admin(impersonatedBy)，并标注被模拟的账号，
            // 保证「谁在以谁身份操作」可追溯(含业务服务显式写的下载/查看事件)。非模拟时绑当前主体。
            boolean impersonating = authUser.getImpersonatedBy() != null;
            UUID auditActorId = impersonating ? authUser.getImpersonatedBy() : authUser.getId();
            String auditActorAccount = impersonating ? null : authUser.getLoginAccount();
            AuditRequestContext.bindVerifiedActor(
                    request, auditActorId, auditActorAccount, sessionId,
                    impersonating ? authUser.getId() : null);
        }
        chain.doFilter(request, response);
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        String contextPath = request.getContextPath();
        if (contextPath != null && !contextPath.isEmpty() && path.startsWith(contextPath)) {
            path = path.substring(contextPath.length());
        }
        return PUBLIC_STAFF_AUTH_PATHS.contains(path)
                || path.startsWith("/api/visitor/auth/");
    }

    /** 解析结果: 成功带主体; 失败带写进安全审计的原因。 */
    private record Resolution(AuthUser user, String reason) {
        static Resolution accepted(AuthUser user) {
            return new Resolution(user, null);
        }

        static Resolution rejected(String reason) {
            return new Resolution(null, reason);
        }
    }

    /**
     * Staff authorization is rebuilt from the current account projection. Status,
     * employee binding, super-admin shape, authorization stamps and the server-side
     * session never trust JWT copies.
     */
    private Resolution resolveStaff(UUID userId, UUID sessionId, Claims claims, boolean automatic) {
        // 模拟身份 token 携带 imp claim（admin userId）。非 null 即触发只读守卫；权限/数据范围仍按目标解析，
        // 会话则是发起模拟的超管自己的会话 (超管登出或空闲超时, 模拟令牌随之失效)。
        // imp 来自签名 token，正常必为合法 UUID；异常时按"无模拟标记"处理（不抛 503）。
        String impClaim = stringClaim(claims, "imp");
        UUID impersonatedBy = null;
        if (impClaim != null) {
            try {
                impersonatedBy = UUID.fromString(impClaim);
            } catch (IllegalArgumentException ex) {
                impersonatedBy = null;
            }
        }
        UUID sessionOwner = impersonatedBy != null ? impersonatedBy : userId;
        AuthSessionService.StaffState user =
                sessions.loadStaff(userId, sessionId, sessionOwner).orElse(null);
        if (user == null || user.deleted() || !"active".equals(user.status())) {
            return Resolution.rejected("account_state_changed");
        }
        Long tokenAuthVersion = numericClaim(claims, "av");
        Long tokenAuthorizationEpoch = numericClaim(claims, "ae");
        if (tokenAuthVersion == null
                || tokenAuthorizationEpoch == null
                || tokenAuthVersion != user.authVersion()
                || tokenAuthorizationEpoch != user.authorizationEpoch()) {
            return Resolution.rejected("account_state_changed");
        }
        UUID employeeId = user.employeeId();
        String loginAccount = user.loginAccount();
        if (employeeId == null || loginAccount == null || loginAccount.isBlank()) {
            return Resolution.rejected("account_state_changed");
        }
        String sessionRejection = checkSession(
                sessionId, user.session(), user.idleTimeoutRaw(), automatic);
        if (sessionRejection != null) {
            return Resolution.rejected(sessionRejection);
        }
        PermissionResolver.AuthorizationSnapshot authorities = staffAuthorityResolver.resolve(
                userId,
                employeeId,
                user.superAdmin(),
                user.authVersion(),
                user.authorizationEpoch());
        return Resolution.accepted(new AuthUser(
                userId,
                employeeId,
                loginAccount,
                authorities.permissions(),
                user.mustChangePassword(),
                true,
                user.superAdmin(),
                user.remoteAccess(),
                impersonatedBy,
                sessionId));
    }

    /** Visitors are rejected when their current server-side account or session is not active. */
    private Resolution resolveVisitor(UUID visitorId, UUID sessionId, Claims claims, boolean automatic) {
        AuthSessionService.VisitorState visitor =
                sessions.loadVisitor(visitorId, sessionId).orElse(null);
        if (visitor == null || !"active".equals(visitor.status())) {
            return Resolution.rejected("account_state_changed");
        }
        String visitorAccount = stringClaim(claims, "acc");
        String visitorNo = stringClaim(claims, "vno");
        Set<String> permissions = asStringSet(claims.get("perms"));
        if (visitorAccount == null || visitorNo == null || permissions == null) {
            return Resolution.rejected("account_state_changed");
        }
        String sessionRejection = checkSession(
                sessionId, visitor.session(), visitor.idleTimeoutRaw(), automatic);
        if (sessionRejection != null) {
            return Resolution.rejected(sessionRejection);
        }
        return Resolution.accepted(
                AuthUser.visitor(visitorId, visitorAccount, visitorNo, permissions, sessionId));
    }

    /** 会话判定: 有效返回 null 并按需续期; 否则返回拒绝原因 (空闲超时顺手落吊销原因)。 */
    private String checkSession(UUID sessionId,
                                AuthSessionService.SessionFacts session,
                                String idleTimeoutRaw,
                                boolean automatic) {
        Instant now = sessions.now();
        AuthSessionService.Verdict verdict = AuthSessionService.evaluate(
                session, AuthSessionService.idleTimeoutMinutes(idleTimeoutRaw), now);
        switch (verdict) {
            case ACTIVE -> {
                if (!automatic) {
                    sessions.touchIfDue(sessionId, session.lastSeenAt(), now);
                }
                return null;
            }
            case IDLE_EXPIRED -> {
                sessions.revokeQuietly(sessionId, AuthSessionService.REASON_IDLE);
                return "session_idle_timeout";
            }
            case ABSOLUTE_EXPIRED -> {
                return "session_expired";
            }
            case REVOKED -> {
                return "session_revoked";
            }
            default -> {
                return "session_missing";
            }
        }
    }

    /** Writes the canonical ApiError wire shape for explicit credential invalidation. */
    private void writeUnauthorized(HttpServletResponse response, String reason) throws IOException {
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        String message = switch (reason == null ? "" : reason) {
            case "session_idle_timeout" -> "长时间没有操作，已自动退出，请重新登录";
            case "session_expired" -> "登录已超过保持时长，请重新登录";
            case "session_revoked", "session_missing" -> "登录已失效，请重新登录";
            default -> "账号状态或权限已变更，请重新登录";
        };
        var body = objectMapper.createObjectNode()
                .put("timestamp", OffsetDateTime.now().toString())
                .put("status", ErrorCode.UNAUTHORIZED.getHttpStatus())
                .put("code", ErrorCode.UNAUTHORIZED.name())
                .put("message", message);
        response.getWriter().write(objectMapper.writeValueAsString(body));
    }

    /** Keeps infrastructure failures distinguishable from a session-invalidating 401. */
    private void writeServiceUnavailable(HttpServletResponse response) throws IOException {
        response.setStatus(HttpServletResponse.SC_SERVICE_UNAVAILABLE);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        var body = objectMapper.createObjectNode()
                .put("timestamp", OffsetDateTime.now().toString())
                .put("status", HttpServletResponse.SC_SERVICE_UNAVAILABLE)
                .put("code", SERVICE_UNAVAILABLE_CODE)
                .put("message", SERVICE_UNAVAILABLE_MESSAGE);
        response.getWriter().write(objectMapper.writeValueAsString(body));
    }

    private String requiredTokenType(Claims claims) {
        Object value = claims.get("typ");
        if (!(value instanceof String type) || type.isBlank()) {
            throw new IllegalArgumentException("missing token type");
        }
        return type;
    }

    private UUID requiredSubjectId(Claims claims) {
        String subject = claims.getSubject();
        if (subject == null || subject.isBlank()) {
            throw new IllegalArgumentException("missing token subject");
        }
        return UUID.fromString(subject);
    }

    private UUID optionalSessionId(Claims claims) {
        Object value = claims.get("sid");
        if (value == null) {
            // 没有会话的令牌一律拒绝 (调用方判定为 session_missing)。
            return null;
        }
        if (!(value instanceof String text) || text.isBlank()) {
            throw new IllegalArgumentException("invalid token session");
        }
        return UUID.fromString(text);
    }

    private Long numericClaim(Claims claims, String name) {
        Object value = claims.get(name);
        return value instanceof Number number ? number.longValue() : null;
    }

    private String stringClaim(Claims claims, String name) {
        Object value = claims.get(name);
        return value instanceof String text && !text.isBlank() ? text : null;
    }

    private Set<String> asStringSet(Object value) {
        if (value == null) {
            return Set.of();
        }
        if (!(value instanceof Collection<?> values)) {
            return null;
        }
        Set<String> result = new HashSet<>();
        for (Object item : values) {
            if (!(item instanceof String text) || text.isBlank()) {
                return null;
            }
            result.add(text);
        }
        return result;
    }
}
