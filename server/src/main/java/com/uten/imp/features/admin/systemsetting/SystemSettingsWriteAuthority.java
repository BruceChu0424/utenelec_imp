package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.UUID;

/** Authoritative administrator lock through save commit; a stale JWT cannot configure a worker. */
@Component
@RequiredArgsConstructor
public class SystemSettingsWriteAuthority {
    private final SecurityContextCurrentUser current;
    private final JdbcTemplate jdbc;
    public void require(UUID expectedActor,boolean write) {
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(!actor.getId().equals(expectedActor)||actor.isVisitor()||actor.isMustChangePassword()||actor.getImpersonatedBy()!=null
                ||!actor.isSuperAdmin()||!actor.isAccountNonLocked()||!actor.getPermissions().contains("authorization:manage"))throw new ApiException(ErrorCode.FORBIDDEN);
        var rows=jdbc.query("SELECT id FROM users WHERE id=? AND is_super_admin AND NOT is_deleted AND status='active' AND NOT must_change_password"
                +(write?" FOR SHARE":""),(r,n)->r.getObject(1,UUID.class),actor.getId());
        if(rows.size()!=1)throw new ApiException(ErrorCode.FORBIDDEN);
    }
}
