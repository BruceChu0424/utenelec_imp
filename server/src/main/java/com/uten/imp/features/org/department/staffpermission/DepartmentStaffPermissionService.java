package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.stereotype.Service;

import java.util.UUID;

/**
 * Legacy staff-permission write route. The old whole-department matrix panel
 * and its single-permission write path were replaced by
 * {@link PagePermissionWorkspaceService}; this service only keeps the
 * compatibility endpoint that answers central personal overrides with an
 * explicit 403. Organization leaders can never mutate
 * {@code user_permission_overrides}.
 */
@Service
public class DepartmentStaffPermissionService {

    public void setStaffOverride(UUID employeeId, String code, String effect) {
        throw new ApiException(
                ErrorCode.FORBIDDEN,
                "负责人不能修改中央个人覆盖，请使用页面权限委派接口");
    }
}
