package com.uten.imp.security;

import com.uten.imp.config.props.DeploymentProperties;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/** Resolves origin from the real listener and numeric source policy, never headers. */
@Component
@RequiredArgsConstructor
public class TrustedRequestOriginPolicy {
    public enum Origin { LOCAL, REMOTE, UNKNOWN }
    public static final String ATTRIBUTE = TrustedRequestOriginPolicy.class.getName() + ".origin";
    private static final ThreadLocal<Origin> CURRENT = new ThreadLocal<>();

    private final DeploymentProperties deployment;
    private final LocalNetworkAccessPolicy localNetwork;

    public Origin resolve(HttpServletRequest request) {
        if (request == null) return Origin.UNKNOWN;
        if (deployment.isRemoteIngressEnabled()
                && request.getLocalPort() == deployment.getRemoteIngressPort()) {
            // Binding the connector to loopback prevents remote socket access. A
            // forwarded remoteAddr is informational and cannot change connector identity.
            return Origin.REMOTE;
        }
        // Retain the historical cloud-site boundary for existing deployments.
        if ("cloud".equalsIgnoreCase(deployment.getSite())) return Origin.REMOTE;
        return localNetwork.isAllowed(request.getRemoteAddr()) ? Origin.LOCAL : Origin.UNKNOWN;
    }

    public Origin current() {
        Origin bound = CURRENT.get();
        if (bound != null) return bound;
        if (RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes attributes) {
            Object resolved = attributes.getRequest().getAttribute(ATTRIBUTE);
            return resolved instanceof Origin origin ? origin : resolve(attributes.getRequest());
        }
        return Origin.UNKNOWN;
    }

    public boolean isRemoteRequest() { return current() == Origin.REMOTE; }

    static void bind(Origin origin) { CURRENT.set(origin); }
    static void clear() { CURRENT.remove(); }
}
