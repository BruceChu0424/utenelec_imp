package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import jakarta.annotation.PostConstruct;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * 部署站点。决定云端门禁（{@code RemoteAccessGuardFilter}）是否启用。
 * <ul>
 *   <li>{@code local}（默认）—— 公司内网，全员可访问，门禁不生效。</li>
 *   <li>{@code cloud} —— 阿里云 ECS，仅 {@code remote_access=TRUE} 的账号可访问。</li>
 * </ul>
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.deployment")
public class DeploymentProperties {

    public static final String DEFAULT_LOCAL_ALLOWED_CIDRS =
            "127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16";

    /** 部署站点：local / cloud。 */
    private String site = "local";

    /** Source networks allowed to reach /api/** when {@link #site} is local. */
    private String localAllowedCidrs = DEFAULT_LOCAL_ALLOWED_CIDRS;

    @PostConstruct
    void validateSite() {
        if (!"local".equalsIgnoreCase(site) && !"cloud".equalsIgnoreCase(site)) {
            throw new IllegalStateException("uten.deployment.site must be local or cloud");
        }
    }
}
