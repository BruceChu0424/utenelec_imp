package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.auth.model.UserAccount;
import org.springframework.stereotype.Component;

/**
 * Server-side authority for staff access through a trusted remote entry.
 *
 * <p>唯一闸门是按账号的外网授权 {@code users.remote_access}（权限设置 → 按员工 → 云端(外网)
 * 访问授权开关）。凭证签发与每个已认证远程请求都复核同一判定，签发侧不得成为绕过请求
 * 过滤器的旁路；授权被收回时 bump auth_version 并吊销全部会话，立即生效。</p>
 */
@Component
public class RemoteAccessPolicy {

    public static final String DENIED_MESSAGE = "该账号未授权外网(云端)访问";

    private final DeploymentProperties deployment;
    private final TrustedRequestOriginPolicy origins;

    @org.springframework.beans.factory.annotation.Autowired
    public RemoteAccessPolicy(DeploymentProperties deployment, TrustedRequestOriginPolicy origins) {
        this.deployment = deployment;
        this.origins = origins;
    }

    /** Compatibility for isolated policy tests; the application always uses the full constructor. */
    public RemoteAccessPolicy(DeploymentProperties deployment) {
        this(deployment, null);
    }

    public void requireStaffAccess(UserAccount account) {
        requireStaffAccess(account.isRemoteAccess());
    }

    public void requireStaffAccess(boolean remoteAccess) {
        if (isRemoteRequest() && !remoteAccess) {
            throw new ApiException(ErrorCode.REMOTE_ACCESS_DENIED, DENIED_MESSAGE);
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
