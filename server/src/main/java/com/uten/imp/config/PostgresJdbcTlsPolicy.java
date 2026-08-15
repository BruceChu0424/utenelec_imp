package com.uten.imp.config;

import org.springframework.util.StringUtils;

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.InvalidPathException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Fail-closed PostgreSQL JDBC TLS policy shared by production data sources.
 *
 * <p>Loopback is identified from literal host values only. The policy never
 * performs DNS resolution: a hostname that happens to resolve to loopback is
 * still treated as remote and therefore requires authenticated TLS.</p>
 */
public final class PostgresJdbcTlsPolicy {

    private static final String JDBC_PREFIX = "jdbc:postgresql://";

    private PostgresJdbcTlsPolicy() {
    }

    /**
     * Requires authenticated TLS unless every configured PostgreSQL host is an
     * explicit loopback literal.
     */
    public static void requireProductionConnection(String property, String url) {
        ParsedUrl parsed = parse(property, url);
        if (allHostsAreLiteralLoopback(property, parsed)) {
            return;
        }
        requireVerifyFullWithExplicitRootCertificate(property, parsed);
    }

    /**
     * Requires authenticated TLS even when the configured host is loopback.
     * Cloud primary/replica pools use this stricter boundary.
     */
    public static void requireAuthenticatedTls(String property, String url) {
        ParsedUrl parsed = parse(property, url);
        requireVerifyFullWithExplicitRootCertificate(property, parsed);
    }

    private static ParsedUrl parse(String property, String url) {
        if (!StringUtils.hasText(url) || !url.startsWith(JDBC_PREFIX)) {
            throw invalid(property, "must be an explicit PostgreSQL JDBC URL");
        }

        int queryIndex = url.indexOf('?', JDBC_PREFIX.length());
        int fragmentIndex = url.indexOf('#', JDBC_PREFIX.length());
        if (fragmentIndex >= 0) {
            throw invalid(property, "must not contain a URL fragment");
        }
        int connectionEnd = queryIndex >= 0 ? queryIndex : url.length();
        int pathIndex = url.indexOf('/', JDBC_PREFIX.length());
        if (pathIndex < 0 || pathIndex >= connectionEnd
                || pathIndex == connectionEnd - 1) {
            throw invalid(property, "must include an explicit database name");
        }

        String authority = url.substring(JDBC_PREFIX.length(), pathIndex);
        if (!StringUtils.hasText(authority) || authority.indexOf('@') >= 0) {
            throw invalid(property, "must contain hosts without embedded credentials");
        }
        List<String> hosts = parseHosts(property, authority);
        Map<String, String> parameters = queryIndex >= 0
                ? parseQuery(property, url.substring(queryIndex + 1))
                : Map.of();
        return new ParsedUrl(hosts, parameters);
    }

    private static List<String> parseHosts(String property, String authority) {
        List<String> hosts = new ArrayList<>();
        int tokenStart = 0;
        int bracketDepth = 0;
        for (int index = 0; index <= authority.length(); index++) {
            char current = index < authority.length() ? authority.charAt(index) : ',';
            if (current == '[') {
                bracketDepth++;
            } else if (current == ']') {
                bracketDepth--;
            }
            if (bracketDepth < 0 || bracketDepth > 1) {
                throw invalid(property, "contains a malformed PostgreSQL host");
            }
            if (current == ',' && bracketDepth == 0) {
                String token = authority.substring(tokenStart, index);
                hosts.add(parseHostToken(property, token));
                tokenStart = index + 1;
            }
        }
        if (bracketDepth != 0 || hosts.isEmpty()) {
            throw invalid(property, "contains a malformed PostgreSQL host");
        }
        return List.copyOf(hosts);
    }

    private static String parseHostToken(String property, String token) {
        if (!StringUtils.hasText(token) || !token.equals(token.trim())) {
            throw invalid(property, "contains an empty or padded PostgreSQL host");
        }

        String host;
        String port = "";
        if (token.startsWith("[")) {
            int closingBracket = token.indexOf(']');
            if (closingBracket <= 1) {
                throw invalid(property, "contains a malformed PostgreSQL IPv6 host");
            }
            host = token.substring(1, closingBracket);
            String remainder = token.substring(closingBracket + 1);
            if (StringUtils.hasText(remainder)) {
                if (!remainder.startsWith(":") || remainder.length() == 1) {
                    throw invalid(property, "contains a malformed PostgreSQL port");
                }
                port = remainder.substring(1);
            }
        } else {
            int firstColon = token.indexOf(':');
            int lastColon = token.lastIndexOf(':');
            if (firstColon != lastColon) {
                throw invalid(property, "requires brackets around PostgreSQL IPv6 hosts");
            }
            if (lastColon >= 0) {
                host = token.substring(0, lastColon);
                port = token.substring(lastColon + 1);
                if (port.isEmpty()) {
                    throw invalid(property, "contains a malformed PostgreSQL port");
                }
            } else {
                host = token;
            }
        }

        if (!StringUtils.hasText(host)
                || host.indexOf('%') >= 0
                || host.chars().anyMatch(Character::isWhitespace)) {
            throw invalid(property, "contains an invalid PostgreSQL host");
        }
        if (StringUtils.hasText(port)) {
            try {
                int parsedPort = Integer.parseInt(port);
                if (!port.chars().allMatch(Character::isDigit)
                        || parsedPort < 1
                        || parsedPort > 65_535) {
                    throw invalid(property, "contains an invalid PostgreSQL port");
                }
            } catch (NumberFormatException exception) {
                throw invalid(property, "contains an invalid PostgreSQL port");
            }
        }
        return host;
    }

    private static Map<String, String> parseQuery(String property, String query) {
        if (!StringUtils.hasText(query)) {
            throw invalid(property, "contains an empty JDBC parameter list");
        }
        Map<String, String> parameters = new LinkedHashMap<>();
        for (String pair : query.split("&", -1)) {
            int separator = pair.indexOf('=');
            if (separator <= 0) {
                throw invalid(property, "contains a malformed JDBC parameter");
            }
            String key = decode(property, pair.substring(0, separator));
            String value = decode(property, pair.substring(separator + 1));
            if (parameters.putIfAbsent(key, value) != null) {
                throw invalid(property, "contains a duplicate JDBC parameter: " + key);
            }
        }
        return Map.copyOf(parameters);
    }

    private static String decode(String property, String value) {
        try {
            return URLDecoder.decode(value, StandardCharsets.UTF_8);
        } catch (IllegalArgumentException exception) {
            throw invalid(property, "contains an invalid encoded JDBC parameter");
        }
    }

    private static boolean allHostsAreLiteralLoopback(
            String property,
            ParsedUrl parsed) {
        if (parsed.hosts().isEmpty()) {
            throw invalid(property, "must name at least one PostgreSQL host");
        }
        for (String rawHost : parsed.hosts()) {
            String host = rawHost.toLowerCase(Locale.ROOT);
            if (!StringUtils.hasText(host)) {
                throw invalid(property, "contains an empty PostgreSQL host");
            }
            if (!isLiteralLoopback(host)) {
                return false;
            }
        }
        return true;
    }

    private static boolean isLiteralLoopback(String host) {
        if ("localhost".equals(host)
                || "localhost.".equals(host)
                || "::1".equals(host)
                || "0:0:0:0:0:0:0:1".equals(host)) {
            return true;
        }

        String[] octets = host.split("\\.", -1);
        if (octets.length != 4 || !"127".equals(octets[0])) {
            return false;
        }
        for (String octet : octets) {
            if (octet.isEmpty() || !octet.chars().allMatch(Character::isDigit)) {
                return false;
            }
            try {
                int value = Integer.parseInt(octet);
                if (value < 0 || value > 255) {
                    return false;
                }
            } catch (NumberFormatException exception) {
                return false;
            }
        }
        return true;
    }

    private static void requireVerifyFullWithExplicitRootCertificate(
            String property,
            ParsedUrl parsed) {
        String sslMode = parsed.parameters().get("sslmode");
        if (!"verify-full".equalsIgnoreCase(sslMode)) {
            throw invalid(property, "must include sslmode=verify-full");
        }

        rejectCustomTlsVerifier(property, parsed);

        String rootCertificate = parsed.parameters().get("sslrootcert");
        String normalizedRootCertificate = rootCertificate == null
                ? null
                : rootCertificate.trim();
        if (!StringUtils.hasText(rootCertificate)
                || !rootCertificate.equals(normalizedRootCertificate)
                || containsPlaceholder(rootCertificate)
                || rootCertificate.chars().anyMatch(Character::isISOControl)
                || !isAbsolutePath(normalizedRootCertificate)) {
            throw invalid(property,
                    "must include an absolute, non-placeholder sslrootcert path");
        }
    }

    private static void rejectCustomTlsVerifier(String property, ParsedUrl parsed) {
        if (StringUtils.hasText(parsed.parameters().get("sslfactory"))) {
            throw invalid(property,
                    "must not override sslfactory under the production TLS policy");
        }
        if (StringUtils.hasText(parsed.parameters().get("sslhostnameverifier"))) {
            throw invalid(property,
                    "must not override sslhostnameverifier under the production TLS policy");
        }
    }

    private static boolean containsPlaceholder(String value) {
        String normalized = value.toUpperCase(Locale.ROOT);
        return normalized.contains("${")
                || normalized.contains("REPLACE")
                || normalized.contains("CHANGE_ME")
                || normalized.indexOf('\0') >= 0;
    }

    private static boolean isAbsolutePath(String value) {
        try {
            // Production deployments are Linux, while unit tests also run on
            // Windows workstations. Recognize a POSIX root independent of the
            // build host, then fall back to the host platform path semantics.
            return value.startsWith("/") || Path.of(value).isAbsolute();
        } catch (InvalidPathException exception) {
            return false;
        }
    }

    private static IllegalStateException invalid(String property, String requirement) {
        return new IllegalStateException(property + " " + requirement);
    }

    private record ParsedUrl(List<String> hosts, Map<String, String> parameters) {
    }
}
