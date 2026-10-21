package com.uten.imp.security;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpHeaders;
import org.springframework.security.web.util.matcher.RequestMatcher;

import java.util.Set;

/** Exact explicit-credential exceptions; ambient browser credentials never exempt an application write. */
public final class ApiCsrfPolicy implements RequestMatcher {
    private static final Set<String> PUBLIC_CREDENTIAL_POSTS = Set.of(
            "/api/auth/login", "/api/auth/refresh", "/api/auth/logout",
            "/api/visitor/auth/send-code", "/api/visitor/auth/login",
            "/api/visitor/auth/refresh", "/api/visitor/auth/logout",
            "/api/website-inquiries/ingest");

    @Override
    public boolean matches(HttpServletRequest request) {
        String path = SecurityRequestPath.withinApplication(request);
        if ("POST".equals(request.getMethod()) && PUBLIC_CREDENTIAL_POSTS.contains(path)) return true;
        if (!SecurityRequestPath.isApi(path)) return false;
        String authorization = request.getHeader(HttpHeaders.AUTHORIZATION);
        // JWT signature/session/permission checks still run before any protected operation.
        // This header is an explicit caller credential, never an automatically attached cookie.
        return authorization != null && authorization.startsWith("Bearer ")
                && !authorization.substring(7).isBlank();
    }
}
