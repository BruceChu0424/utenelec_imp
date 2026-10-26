package com.uten.imp.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.net.URI;
import java.net.URISyntaxException;

/**
 * Validates the container's effective authority before the HTTPS redirect parser.
 * Spring's RFC parser rejects the dotted IPv4 tail of otherwise valid IPv6 literals.
 * Canonicalizing only that numeric tail avoids DNS and keeps the HTTPS policy intact.
 * Forwarding headers remain exclusively owned by the configured trusted proxy valve.
 */
public final class HttpsRequestAuthorityFilter extends OncePerRequestFilter {
    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String canonical;
        try {
            canonical = canonicalHost(request.getServerName(), request.getServerPort());
        } catch (IllegalArgumentException invalid) {
            // Do not dispatch /error, reflect the untrusted authority, or log request secrets.
            response.setStatus(HttpServletResponse.SC_BAD_REQUEST);
            response.setContentLength(0);
            return;
        }
        if ("https".equals(request.getScheme()) || canonical.equals(request.getServerName())) {
            chain.doFilter(request, response);
        } else {
            chain.doFilter(new HttpServletRequestWrapper(request) {
                @Override
                public String getServerName() {
                    return canonical;
                }
            }, response);
        }
    }

    static String canonicalHost(String host, int port) {
        if (host == null || host.isEmpty() || port < 1 || port > 65535
                || host.chars().anyMatch(c -> c <= 32 || c == 127 || "/\\?#@%".indexOf(c) >= 0)) {
            throw new IllegalArgumentException("Invalid request authority");
        }
        String literal = host.indexOf(':') >= 0 && !host.startsWith("[") ? "[" + host + "]" : host;
        validateAuthority(literal, port);
        if (!literal.startsWith("[") || literal.indexOf('.') < 0) {
            return literal;
        }
        int tail = literal.lastIndexOf(':') + 1;
        String[] octets = literal.substring(tail, literal.length() - 1).split("\\.", -1);
        if (octets.length != 4) throw new IllegalArgumentException("Invalid request authority");
        int[] value = new int[4];
        for (int i = 0; i < value.length; i++) {
            if (!octets[i].matches("0|[1-9][0-9]{0,2}")) {
                throw new IllegalArgumentException("Invalid request authority");
            }
            value[i] = Integer.parseInt(octets[i]);
            if (value[i] > 255) throw new IllegalArgumentException("Invalid request authority");
        }
        String canonical = literal.substring(0, tail)
                + Integer.toHexString((value[0] << 8) | value[1]) + ":"
                + Integer.toHexString((value[2] << 8) | value[3]) + "]";
        validateAuthority(canonical, port);
        return canonical;
    }

    private static void validateAuthority(String host, int port) {
        try {
            URI authority = new URI("http://" + host + ":" + port + "/").parseServerAuthority();
            if (authority.getHost() == null || authority.getRawUserInfo() != null
                    || authority.getPort() != port || !"/".equals(authority.getRawPath())
                    || authority.getRawQuery() != null || authority.getRawFragment() != null) {
                throw new IllegalArgumentException("Invalid request authority");
            }
        } catch (URISyntaxException invalid) {
            throw new IllegalArgumentException("Invalid request authority", invalid);
        }
    }
}
