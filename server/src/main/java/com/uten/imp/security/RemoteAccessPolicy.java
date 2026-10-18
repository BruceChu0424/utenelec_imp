package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.admin.remoteaccess.RemoteAccessSettingsService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

/**
 * Server-side authority for staff access through a trusted remote entry.
 *
 * <p>The policy is deliberately checked both while issuing credentials and on every
 * authenticated remote request. Credential issuance must not become an alternate path
 * around the request filter.
 */
@Component
public class RemoteAccessPolicy {

    public static final String DENIED_MESSAGE = "该账号未授权外网(云端)访问";

    private final DeploymentProperties deployment;
    private final TrustedRequestOriginPolicy origins;
    private final RemoteAccessSettingsService settings;

    @Autowired
    public RemoteAccessPolicy(DeploymentProperties deployment, TrustedRequestOriginPolicy origins,
                              RemoteAccessSettingsService settings) {
        this.deployment = deployment;
        this.origins = origins;
        this.settings = settings;
    }

    /** Compatibility for isolated policy tests; the application always uses the full constructor. */
    public RemoteAccessPolicy(DeploymentProperties deployment) {
        this(deployment, null, null);
    }

    public void requireStaffAccess(UserAccount account) {
        requireStaffAccess(account.isRemoteAccess());
    }

    public void requireStaffAccess(boolean remoteAccess) {
        if (isRemoteRequest()) {
            if (!remoteAccess) throw new ApiException(ErrorCode.REMOTE_ACCESS_DENIED, DENIED_MESSAGE);
            if (settings != null && !settings.isEnabled()) {
                throw new ApiException(ErrorCode.REMOTE_ACCESS_DENIED,"公司当前已关闭员工外网访问，请通过公司内部入口使用");
            }
        }
    }

    public void requireAuthenticatedAccess(AuthUser principal) {
        // Visitor authentication is an intentional public-cloud boundary. Visitors do
        // not have users.remote_access; their status and permissions are enforced by the
        // visitor authentication flow and JwtAuthFilter instead.
        if (principal.isVisitor()) {
            if (isRemoteRequest() && !isCloud()) {
                throw new ApiException(ErrorCode.FORBIDDEN,"当前远程入口仅供获授权员工使用");
            }
            return;
        }
        if (!isRemoteRequest()) return;
        if (!principal.isRemoteAccess()) throw new ApiException(ErrorCode.REMOTE_ACCESS_DENIED,DENIED_MESSAGE);
        if (!principal.isRemotePolicyEnabled()) {
            throw new ApiException(ErrorCode.REMOTE_ACCESS_DENIED,"公司当前已关闭员工外网访问，请通过公司内部入口使用");
        }
        if (principal.getImpersonatedBy() != null) {
            throw new ApiException(ErrorCode.FORBIDDEN,"请在公司内部入口使用模拟员工视角");
        }
    }

    public boolean isRemoteRequest() {
        return isCloud() || (origins != null && origins.isRemoteRequest());
    }

    public boolean isCloud() {
        return "cloud".equalsIgnoreCase(deployment.getSite());
    }
}
