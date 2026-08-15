package com.uten.imp.config;

import org.springframework.beans.factory.config.BeanFactoryPostProcessor;
import org.springframework.beans.factory.config.ConfigurableListableBeanFactory;
import org.springframework.context.annotation.Lazy;
import org.springframework.context.EnvironmentAware;
import org.springframework.core.Ordered;
import org.springframework.core.PriorityOrdered;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Fail-closed guard for the dedicated on-premises ERP test runtime.
 *
 * <p>This profile keeps the production network, migration, secret and API
 * documentation boundaries while permitting only the fixed NVMe-backed local
 * attachment namespace. The independent {@link ProductionStorageSafetyGate}
 * continues to require OSS for {@code prod}/{@code cloud}.</p>
 */
@Component
@Lazy(false)
public class InternalTestRuntimeSafetyGate
        implements BeanFactoryPostProcessor, PriorityOrdered, EnvironmentAware {

    static final String PROFILE = "internal-test";
    static final String LOCAL_ATTACHMENT_ROOT = "/data/uten-imp/attachments";
    private static final Profiles INTERNAL_TEST = Profiles.of(PROFILE);
    private static final int MAX_LOCAL_CIDRS = 8;
    private static final Pattern IPV4_CIDR = Pattern.compile(
            "^((?:0|[1-9][0-9]{0,2}))\\.((?:0|[1-9][0-9]{0,2}))\\."
                    + "((?:0|[1-9][0-9]{0,2}))\\.((?:0|[1-9][0-9]{0,2}))/"
                    + "(0|[1-9][0-9]?)$");

    private Environment environment;

    public InternalTestRuntimeSafetyGate() {
    }

    @Override
    public void setEnvironment(Environment environment) {
        this.environment = environment;
    }

    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE;
    }

    @Override
    public void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory) {
        validate();
    }

    void validate() {
        if (environment == null) {
            throw new IllegalStateException("internal-test runtime environment was not injected");
        }
        if (!environment.acceptsProfiles(INTERNAL_TEST)) {
            return;
        }

        requireExclusiveProfile();
        requireExact("server.address", "127.0.0.1");
        requireExact("server.port", "8080");
        requireExact("server.forward-headers-strategy", "native");
        requireExact("server.tomcat.remoteip.internal-proxies", "127\\..*|::1");
        requireExact("server.ssl.enabled", "false");

        requireExact("spring.main.lazy-initialization", "false");
        requireExact("spring.flyway.enabled", "false");
        requireExact("spring.datasource.url",
                "jdbc:postgresql://127.0.0.1:5432/uten_imp");
        requireExact("spring.datasource.username", "uten");
        requireSecret("spring.datasource.password", 20);

        requireExact("uten.deployment.site", "local");
        requireNarrowLocalCidrs();
        requireHttpsCorsOrigins();
        requireExact("uten.security.require-https", "true");
        requireExact("uten.security.swagger-enabled", "false");
        requireBootstrapLogin();
        requireExact("springdoc.api-docs.enabled", "false");
        requireExact("springdoc.swagger-ui.enabled", "false");

        requireSecret("uten.jwt.secret", 32);
        requireValue("uten.jwt.issuer");
        requireSecret("uten.crypto.pgp-master-key", 32);
        requireSecret("uten.crypto.hmac-key", 32);

        requireExact("uten.sms.provider", "disabled");
        requireExact("uten.sms.expose-code", "false");
        requireExact("uten.policy-intelligence.enabled", "false");
        requireBlank("uten.policy-intelligence.api-key");
        requireBlank("uten.website.inquiry-ingest-token");
        requireExact("app.legacy.enabled", "false");

        requireExact("uten.storage.provider", "local");
        requireExact("uten.storage.local-dir", LOCAL_ATTACHMENT_ROOT);
        requireExact("uten.storage.uploads-enabled", "false");
        requireExact("uten.storage.malware-scan.provider", "disabled");
        requireExact("uten.storage.reconciliation.enabled", "false");
        for (String unusedOssProperty : Set.of(
                "uten.storage.oss.endpoint",
                "uten.storage.oss.internal-endpoint",
                "uten.storage.oss.staging-bucket",
                "uten.storage.oss.final-bucket",
                "uten.storage.oss.region",
                "uten.storage.oss.access-key-id",
                "uten.storage.oss.access-key-secret",
                "uten.storage.oss.role-name")) {
            requireBlank(unusedOssProperty);
        }
    }

    private void requireExclusiveProfile() {
        String[] active = environment.getActiveProfiles();
        if (active.length != 1 || !PROFILE.equals(active[0])) {
            throw new IllegalStateException(
                    "internal-test must be the only active Spring profile");
        }
    }

    private void requireNarrowLocalCidrs() {
        String configured = requireValue("uten.deployment.local-allowed-cidrs");
        String[] cidrs = configured.split(",", -1);
        if (cidrs.length == 0 || cidrs.length > MAX_LOCAL_CIDRS) {
            throw new IllegalStateException(
                    "internal-test requires exact office CIDR entries");
        }
        Set<String> unique = new HashSet<>();
        for (String raw : cidrs) {
            String cidr = raw.trim();
            if (!StringUtils.hasText(cidr)
                    || !cidr.equals(raw)
                    || !unique.add(cidr)
                    || !isAllowedNarrowLocalCidr(cidr)) {
                throw new IllegalStateException(
                        "internal-test requires exact, non-broad office CIDR entries");
            }
        }
    }

    private static boolean isAllowedNarrowLocalCidr(String cidr) {
        if ("::1/128".equals(cidr)) {
            return true;
        }
        Matcher matcher = IPV4_CIDR.matcher(cidr);
        if (!matcher.matches()) {
            return false;
        }
        long address = 0;
        for (int index = 1; index <= 4; index++) {
            int octet = Integer.parseInt(matcher.group(index));
            if (octet > 255) {
                return false;
            }
            address = (address << 8) | octet;
        }
        int prefix = Integer.parseInt(matcher.group(5));
        if (prefix > 32 || (address & prefixMask(prefix)) != address) {
            return false;
        }
        return isWithin(address, prefix, 0x7f000000L, 8, false)
                || isWithin(address, prefix, 0x0a000000L, 8, true)
                || isWithin(address, prefix, 0xac100000L, 12, true)
                || isWithin(address, prefix, 0xc0a80000L, 16, true);
    }

    private static boolean isWithin(
            long address,
            int prefix,
            long parentAddress,
            int parentPrefix,
            boolean requireStrictSubnet) {
        if (prefix < parentPrefix || (requireStrictSubnet && prefix == parentPrefix)) {
            return false;
        }
        return (address & prefixMask(parentPrefix)) == parentAddress;
    }

    private static long prefixMask(int prefix) {
        if (prefix == 0) {
            return 0;
        }
        return (0xffffffffL << (32 - prefix)) & 0xffffffffL;
    }

    private void requireHttpsCorsOrigins() {
        String configured = requireValue("uten.security.cors-allowed-origins");
        for (String raw : configured.split(",", -1)) {
            if (!raw.equals(raw.trim()) || !StringUtils.hasText(raw)) {
                throw invalidCors();
            }
            try {
                URI origin = URI.create(raw);
                if (!"https".equalsIgnoreCase(origin.getScheme())
                        || !StringUtils.hasText(origin.getHost())
                        || origin.getUserInfo() != null
                        || StringUtils.hasText(origin.getPath())
                        || origin.getQuery() != null
                        || origin.getFragment() != null) {
                    throw invalidCors();
                }
            } catch (IllegalArgumentException e) {
                throw new IllegalStateException(
                        "internal-test CORS origins must be exact HTTPS origins", e);
            }
        }
    }

    private void requireBootstrapLogin() {
        String value = requireValue("uten.bootstrap.admin-login");
        if (value.length() > 128 || value.chars().anyMatch(Character::isWhitespace)) {
            throw new IllegalStateException(
                    "internal-test bootstrap login must be one approved account identifier");
        }
    }

    private static IllegalStateException invalidCors() {
        return new IllegalStateException(
                "internal-test CORS origins must be exact HTTPS origins");
    }

    private String requireValue(String key) {
        String value = environment.getProperty(key);
        if (!StringUtils.hasText(value)
                || value.contains("REPLACE")
                || value.contains("CHANGE_ME")) {
            throw new IllegalStateException(
                    "internal-test requires a non-placeholder value for " + key);
        }
        return value;
    }

    private void requireSecret(String key, int minimumUtf8Bytes) {
        String value = requireValue(key);
        if (value.getBytes(StandardCharsets.UTF_8).length < minimumUtf8Bytes) {
            throw new IllegalStateException(
                    "internal-test secret is too short: " + key);
        }
    }

    private void requireExact(String key, String expected) {
        String actual = environment.getProperty(key);
        if (!expected.equals(actual)) {
            throw new IllegalStateException(
                    "internal-test requires " + key + "=" + expected);
        }
    }

    private void requireBlank(String key) {
        if (StringUtils.hasText(environment.getProperty(key))) {
            throw new IllegalStateException(
                    "internal-test forbids unused external credential/config: " + key);
        }
    }
}
