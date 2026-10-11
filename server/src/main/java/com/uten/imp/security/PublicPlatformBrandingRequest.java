package com.uten.imp.security;

import jakarta.servlet.http.HttpServletRequest;

/** Exactly two anonymous GET resources. An incidental stale bearer must not prevent login branding. */
public final class PublicPlatformBrandingRequest {
    private PublicPlatformBrandingRequest() {}

    public static boolean matches(HttpServletRequest request) {
        if (!"GET".equals(request.getMethod())) return false;
        String path = request.getRequestURI();
        String contextPath = request.getContextPath();
        if (contextPath != null && !contextPath.isEmpty() && path.startsWith(contextPath))
            path = path.substring(contextPath.length());
        return "/api/platform/branding".equals(path) || "/api/platform/branding/logo".equals(path);
    }
}
