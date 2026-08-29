package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.auth.model.UserAccount;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * Server-side authority for staff access to the cloud site.
 *
 * <p>The policy is deliberately checked both while issuing credentials and on every
 * authenticated cloud request. Credential issuance must not become an alternate path
 * around the request filter.
 */
@Component
@RequiredArgsConstructor
public class RemoteAccessPolicy {

    public static final String DENIED_MESSAGE = "该账号未授权外网(云端)访问";

    private final DeploymentProperties deployment;

    public void requireStaffAccess(UserAccount account) {
        requireStaffAccess(account.isRemoteAccess());
    }

    public void requireStaffAccess(boolean remoteAccess) {
        if (isCloud() && !remoteAccess) {
            throw new ApiException(ErrorCode.REMOTE_ACCESS_DENIED, DENIED_MESSAGE);
        }
    }

    public void requireAuthenticatedAccess(AuthUser principal) {
        // Visitor authentication is an intentional public-cloud boundary. Visitors do
        // not have users.remote_access; their status and permissions are enforced by the
        // visitor authentication flow and JwtAuthFilter instead.
        if (principal.isVisitor()) {
            return;
        }
        requireStaffAccess(principal.isRemoteAccess());
    }

    public boolean isCloud() {
        return "cloud".equalsIgnoreCase(deployment.getSite());
    }
}
