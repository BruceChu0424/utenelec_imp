package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.visitor.VisitorAccountRepository;
import io.jsonwebtoken.Claims;
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
import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/**
 * Parses bearer access tokens and rebuilds the current principal from server-side
 * account and authorization state.
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
    private final UserAccountRepository userRepo;
    private final VisitorAccountRepository visitorRepo;
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
            try {
                claims = jwtService.parse(token);
                tokenType = requiredTokenType(claims);
                subjectId = requiredSubjectId(claims);
            } catch (JwtException | IllegalArgumentException ex) {
                SecurityContextHolder.clearContext();
                chain.doFilter(request, response);
                return;
            }

            AuthUser authUser;
            try {
                authUser = switch (tokenType) {
                    case "staff" -> resolveStaff(subjectId, claims);
                    case "visitor" -> resolveVisitor(subjectId, claims);
                    default -> null;
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
            if (authUser == null) {
                // Keep this branch outside the token-parsing catch. A response-serialization
                // failure must never fall through to the protected endpoint.
                SecurityContextHolder.clearContext();
                try {
                    auditService.logSecurityEvent(
                            request, null, null,
                            "access_denied", "account_state_changed", 401);
                } catch (RuntimeException ignored) {
                    // Authentication rejection must remain fail-closed if the audit sink is down.
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

    /**
     * Staff authorization is rebuilt from the current account projection. Status,
     * employee binding, super-admin shape and authorization stamps never trust JWT
     * copies.
     */
    private AuthUser resolveStaff(UUID userId, Claims claims) {
        UserAccountRepository.AccountState user = userRepo.findAccountStateById(userId).orElse(null);
        if (user == null || user.isDeleted() || !"active".equals(user.getStatus())) {
            return null;
        }
        Long tokenAuthVersion = numericClaim(claims, "av");
        Long tokenAuthorizationEpoch = numericClaim(claims, "ae");
        if (tokenAuthVersion == null
                || tokenAuthorizationEpoch == null
                || tokenAuthVersion != user.getAuthVersion()
                || tokenAuthorizationEpoch != user.getAuthorizationEpoch()) {
            return null;
        }
        UUID employeeId = user.getEmployeeId();
        String loginAccount = user.getLoginAccount();
        if (employeeId == null || loginAccount == null || loginAccount.isBlank()) {
            return null;
        }
        PermissionResolver.AuthorizationSnapshot authorities = staffAuthorityResolver.resolve(
                userId,
                employeeId,
                user.isSuperAdmin(),
                user.getAuthVersion(),
                user.getAuthorizationEpoch());
        return new AuthUser(
                userId,
                employeeId,
                loginAccount,
                authorities.roles(),
                authorities.permissions(),
                user.isMustChangePassword(),
                true,
                user.isSuperAdmin());
    }

    /** Visitors are rejected when their current server-side account is not active. */
    private AuthUser resolveVisitor(UUID visitorId, Claims claims) {
        VisitorAccountRepository.AccountState visitor =
                visitorRepo.findAccountStateById(visitorId).orElse(null);
        if (visitor == null || !"active".equals(visitor.getStatus())) {
            return null;
        }
        String visitorAccount = stringClaim(claims, "acc");
        String visitorNo = stringClaim(claims, "vno");
        Set<String> permissions = asStringSet(claims.get("perms"));
        if (visitorAccount == null || visitorNo == null || permissions == null) {
            return null;
        }
        return AuthUser.visitor(visitorId, visitorAccount, visitorNo, permissions);
    }

    /** Writes the canonical ApiError wire shape for explicit credential invalidation. */
    private void writeUnauthorized(HttpServletResponse response) throws IOException {
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        var body = objectMapper.createObjectNode()
                .put("timestamp", OffsetDateTime.now().toString())
                .put("status", ErrorCode.UNAUTHORIZED.getHttpStatus())
                .put("code", ErrorCode.UNAUTHORIZED.name())
                .put("message", "账号状态或权限已变更，请重新登录");
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
