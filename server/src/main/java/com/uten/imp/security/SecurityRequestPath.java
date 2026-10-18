package com.uten.imp.security;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.security.web.firewall.RequestRejectedException;
import org.springframework.web.util.UriUtils;

import java.nio.charset.StandardCharsets;

/**
 * One routing identity for all security boundaries. Servlet path + path info are already decoded
 * by the container and relative to the context; decoding them again would disagree with routing.
 * Mock/synthetic requests without a servlet mapping use a single URI-path decode as a fallback.
 */
public final class SecurityRequestPath {
    private SecurityRequestPath() {}

    public static String withinApplication(HttpServletRequest request) {
        String servletPath = request.getServletPath();
        String pathInfo = request.getPathInfo();
        if (servletPath != null && !servletPath.isEmpty() || pathInfo != null && !pathInfo.isEmpty()) {
            return validate((servletPath == null ? "" : servletPath) + (pathInfo == null ? "" : pathInfo));
        }
        String path;
        try {
            String raw = request.getRequestURI();
            if (raw == null) throw new IllegalArgumentException("Missing request path");
            path = UriUtils.decode(raw, StandardCharsets.UTF_8);
            String context = request.getContextPath();
            if (context != null && !context.isEmpty()) {
                context = UriUtils.decode(context, StandardCharsets.UTF_8);
                if (path.equals(context)) path = "/";
                else if (path.startsWith(context + "/")) path = path.substring(context.length());
                else throw new IllegalArgumentException("Invalid context boundary");
            }
        } catch (IllegalArgumentException invalid) {
            throw new RequestRejectedException("Invalid request path");
        }
        return validate(path);
    }

    public static boolean isApi(String path) { return path.equals("/api") || path.startsWith("/api/"); }
    public static boolean isHealth(String path) { return path.equals("/actuator/health") || path.startsWith("/actuator/health/"); }

    private static String validate(String path) {
        if (!path.startsWith("/") || path.indexOf('\\') >= 0 || path.indexOf(';') >= 0
                || path.contains("//") || path.chars().anyMatch(c -> c < 32 || c == 127)) {
            throw new RequestRejectedException("Invalid request path");
        }
        for (String segment : path.split("/", -1)) {
            if (segment.equals(".") || segment.equals("..")) throw new RequestRejectedException("Invalid request path");
        }
        return path;
    }
}
