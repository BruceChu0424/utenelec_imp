package com.uten.imp.features.org.employee;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * 员工档案附件（合同/证件/学历/照片/其他）的对象级授权。
 *
 * <ul>
 *   <li>查看：本人可看自己的档案文件；或持 employee:view（HR/管理层）。</li>
 *   <li>管理（上传/删除/设头像）：仅持 employee:edit（HR 统一维护）。</li>
 * </ul>
 * <p>通用附件层只挡无 attachment:view/manage 的人；真正"只能看自己、不能枚举他人"靠本策略。
 * 拒绝一律返回 NOT_FOUND（与报销策略一致），避免用附件接口枚举无权员工。
 */
@Component
@RequiredArgsConstructor
public class EmployeeAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {

    public static final String OWNER_TYPE = "EMPLOYEE";

    private final EmployeeRepository employeeRepository;

    @Override
    public String ownerType() {
        return OWNER_TYPE;
    }

    @Override
    public void requireCanView(UUID ownerId, AuthUser user) {
        requireEmployee(ownerId);
        if (user.isSuperAdmin()) {
            return;
        }
        // 本人可看自己的档案文件
        if (ownerId.equals(user.getEmployeeId())) {
            return;
        }
        if (user.getPermissions().contains("employee:view")) {
            return;
        }
        throw notFound();
    }

    @Override
    public void requireCanManage(UUID ownerId, AuthUser user) {
        requireEmployee(ownerId);
        if (user.isSuperAdmin() || user.getPermissions().contains("employee:edit")) {
            return;
        }
        throw notFound();
    }

    /** 员工档案无单据状态机跳变，更新时同 manage 校验即可。 */
    @Override
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        requireCanManage(ownerId, user);
    }

    private void requireEmployee(UUID ownerId) {
        if (ownerId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定员工");
        }
        // 仅校验存在性（含软删员工也不允许挂附件）；不泄露是否存在给无权者——统一 NOT_FOUND。
        if (employeeRepository.findById(ownerId).isEmpty()) {
            throw notFound();
        }
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "员工不存在");
    }
}
