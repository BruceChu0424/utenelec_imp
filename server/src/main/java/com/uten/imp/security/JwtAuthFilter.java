package com.uten.imp.security;

import com.uten.imp.features.rbac.UserAccount;
import com.uten.imp.features.rbac.UserAccountRepository;
import com.uten.imp.features.visitor.VisitorAccount;
import com.uten.imp.features.visitor.VisitorAccountRepository;
import io.jsonwebtoken.Claims;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.time.OffsetDateTime;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 解析 Authorization: Bearer access-jwt，按 typ claim 区分主体并**复查 DB 状态**：
 * <ul>
 *   <li>staff：停用/锁定/软删 → 拒绝；mcp 以 DB 为准（管理员重置后立即降权）</li>
 *   <li>visitor：blocked → 拒绝</li>
 * </ul>
 */
@Component
@RequiredArgsConstructor
public class JwtAuthFilter extends OncePerRequestFilter {

    private final JwtService jwtService;
    private final UserAccountRepository userRepo;
    private final VisitorAccountRepository visitorRepo;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {

        String header = request.getHeader("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            String token = header.substring(7);
            try {
                Claims c = jwtService.parse(token);
                String typ = c.get("typ", String.class);
                UUID subjectId = UUID.fromString(c.getSubject());

                AuthUser authUser = "visitor".equals(typ)
                        ? resolveVisitor(subjectId, c)
                        : resolveStaff(subjectId, c);

                if (authUser != null) {
                    UsernamePasswordAuthenticationToken auth =
                            new UsernamePasswordAuthenticationToken(authUser, null, authUser.getAuthorities());
                    SecurityContextHolder.getContext().setAuthentication(auth);
                } else {
                    SecurityContextHolder.clearContext();
                }
            } catch (Exception ex) {
                SecurityContextHolder.clearContext();
            }
        }
        chain.doFilter(request, response);
    }

    /** 员工：复查 users 状态（停用/锁定/软删 → 拒绝；mcp 以 DB 为准）。 */
    private AuthUser resolveStaff(UUID userId, Claims c) {
        UserAccount user = userRepo.findById(userId).orElse(null);
        if (user == null || user.isDeleted()
                || "disabled".equals(user.getStatus())
                || (user.getLockedUntil() != null && user.getLockedUntil().isAfter(OffsetDateTime.now()))) {
            return null;
        }
        UUID employeeId = c.get("emp", String.class) == null ? null
                : UUID.fromString(c.get("emp", String.class));
        String loginAccount = c.get("acc", String.class);
        Set<String> roles = new HashSet<>(asStringList(c.get("roles")));
        Set<String> perms = new HashSet<>(asStringList(c.get("perms")));
        boolean mcp = user.isMustChangePassword();
        return new AuthUser(userId, employeeId, loginAccount, roles, perms, mcp, true);
    }

    /** 访客：复查 visitor_accounts 状态（blocked → 拒绝）。 */
    private AuthUser resolveVisitor(UUID visitorId, Claims c) {
        VisitorAccount va = visitorRepo.findById(visitorId).orElse(null);
        if (va == null || "blocked".equals(va.getStatus())) {
            return null;
        }
        String phone = c.get("acc", String.class);
        String visitorNo = c.get("vno", String.class);
        Set<String> perms = new HashSet<>(asStringList(c.get("perms")));
        return AuthUser.visitor(va.getId(), phone, visitorNo, perms);
    }

    @SuppressWarnings("unchecked")
    private List<String> asStringList(Object o) {
        return o instanceof List<?> l ? (List<String>) l : List.of();
    }
}
