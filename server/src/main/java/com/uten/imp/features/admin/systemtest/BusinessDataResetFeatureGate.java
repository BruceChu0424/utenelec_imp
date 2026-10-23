package com.uten.imp.features.admin.systemtest;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

import java.net.URI;

/**
 * 工作台「清空业务数据」的运行配置开关。
 *
 * <p>上线后所有服务器下架此功能。只有 dev profile、local site、明确绑定回环地址，
 * 且数据库 URL 也指向回环地址的本地开发实例可用；普通开关无法恢复服务器能力。
 * 数据库执行授权独立撤销，本地测试需由本地数据库管理员显式恢复授权。</p>
 */
@Slf4j
@Component
public final class BusinessDataResetFeatureGate {

    public static final String PROPERTY = "uten.features.business-data-reset-enabled";

    private final boolean enabled;

    @org.springframework.beans.factory.annotation.Autowired
    public BusinessDataResetFeatureGate(
            @Value("$" + "{" + PROPERTY + ":false}") boolean enabled,
            @Value("$" + "{uten.deployment.site:local}") String site,
            Environment environment) {
        String[] profiles = environment.getActiveProfiles();
        boolean localDevelopment = profiles.length == 1 && "dev".equals(profiles[0])
                && "local".equals(site)
                && loopback(environment.getProperty("server.address", ""))
                && localDatabase(environment.getProperty("spring.datasource.url", ""));
        if (enabled && !localDevelopment) {
            log.warn("忽略 {}=true：业务数据清空只允许回环地址上的本地开发实例，服务器已下架此功能", PROPERTY);
        }
        this.enabled = enabled && localDevelopment;
    }

    /** Isolated tests only; Spring always uses the environment-checked constructor. */
    public BusinessDataResetFeatureGate(boolean enabled) {
        this.enabled = enabled;
    }

    public boolean enabled() {
        return enabled;
    }

    public void requireEnabled() {
        if (!enabled) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "服务器已下架业务数据清空，仅本地开发测试可用");
        }
    }

    private static boolean loopback(String host) {
        return "127.0.0.1".equals(host) || "::1".equals(host) || "[::1]".equals(host)
                || "localhost".equals(host);
    }

    private static boolean localDatabase(String jdbcUrl) {
        if (!jdbcUrl.startsWith("jdbc:postgresql://")) return false;
        try {
            URI uri = URI.create(jdbcUrl.substring("jdbc:".length()));
            // Reject multi-host URLs, aliases, credentials and JDBC target overrides.
            return loopback(uri.getHost()) && uri.getUserInfo() == null
                    && uri.getRawQuery() == null && uri.getFragment() == null
                    && uri.getPath() != null && uri.getPath().matches("/[A-Za-z0-9_]+")
                    && uri.getPort() > 0;
        } catch (IllegalArgumentException ignored) {
            return false;
        }
    }
}
