package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import jakarta.annotation.PostConstruct;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;
import java.time.Duration;

/**
 * 部署位置与公司受控远程connector。位置不再代替请求入口身份。
 * <ul>
 *   <li>{@code local}（默认）—— 办公connector按公司CIDR，专用remote connector按远程授权与MFA。</li>
 *   <li>{@code cloud} —— 历史站点兼容，全部员工请求视为远程；新方案不在云上运行此业务实例。</li>
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

    /** Extra loopback connector used exclusively by the authenticated remote transport. */
    private boolean remoteIngressEnabled = false;
    private int remoteIngressPort = 8082;

    /** A bounded share of request capacity; local requests never acquire these permits. */
    private int remoteMaxConcurrentRequests = 8;

    /** Finite no-progress budget for remote response writes, separate from request/header reads. */
    private Duration remoteWriteTimeout = Duration.ofSeconds(60);

    public long requireRemoteWriteTimeoutMillis() {
        if (remoteWriteTimeout == null || remoteWriteTimeout.isNegative() || remoteWriteTimeout.isZero()
                || remoteWriteTimeout.compareTo(Duration.ofMinutes(5)) > 0 || remoteWriteTimeout.toMillis() < 1) {
            throw new IllegalStateException("uten.deployment.remote-write-timeout must be at least 1ms and at most 5min");
        }
        return remoteWriteTimeout.toMillis();
    }

    @PostConstruct
    void validateSite() {
        if (!"local".equalsIgnoreCase(site) && !"cloud".equalsIgnoreCase(site)) {
            throw new IllegalStateException("uten.deployment.site must be local or cloud");
        }
        if (remoteIngressPort < 1024 || remoteIngressPort > 65535) {
            throw new IllegalStateException("uten.deployment.remote-ingress-port must be 1024..65535");
        }
        if (remoteMaxConcurrentRequests < 1 || remoteMaxConcurrentRequests > 128) {
            throw new IllegalStateException("uten.deployment.remote-max-concurrent-requests must be 1..128");
        }
        requireRemoteWriteTimeoutMillis();
    }
}
