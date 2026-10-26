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
 *   <li>查看：本人可看自己的档案文件；或持 employee:pii:view（HR/超管；员工档案文件含
 *       身份证件/合同扫描件，属 PII 级敏感材料——注意不能用 employee:view，该权限因
 *       员工选择器需求已授予几乎所有部门，见 V212 矩阵与 2026-08-16 保密审计）。</li>
 *   <li>上传/删除：employee:edit；设为头像：employee:avatar_edit，互不替代。</li>
 * </ul>
 * <p>通用层分别校验 view/upload/delete/download；对象范围仍由本策略收口。
 * 拒绝一律返回 NOT_FOUND（与报销策略一致），避免用附件接口枚举无权员工。
 */
@Component
@RequiredArgsConstructor
public class EmployeeAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {

    public static final String OWNER_TYPE = "EMPLOYEE";

    private final EmployeeRepository employeeRepository;
    private final com.uten.imp.application.port.EmployeeIdentityLookupPort employeeIdentities;

    @Override
    public String ownerType() {
        return OWNER_TYPE;
    }

    @Override
    public void requireCanView(UUID ownerId, AuthUser user) {
        requireStaff(user);
        requireEmployee(ownerId);
        if (user.isSuperAdmin() || user.getPermissions().contains("employee:pii:view")) {
            return;
        }
        // 本人可看自己的档案文件
        if (isSelf(ownerId,user)) {
            return;
        }
        // 档案文件=身份证件/合同扫描件级 PII：按 employee:pii:view 门控，不随 employee:view 扩散
        throw notFound();
    }

    @Override
    public void requireCanViewAvatar(UUID ownerId, AuthUser user) {
        if (user == null || user.isVisitor() || user.isMustChangePassword()) {
            throw notFound();
        }
        requireEmployee(ownerId);
        if (user.isSuperAdmin() || isSelf(ownerId,user)
                || user.getPermissions().contains("employee:view")) {
            return;
        }
        throw notFound();
    }

    @Override
    public void requireCanManage(UUID ownerId, AuthUser user) {
        requireWritable(ownerId,user,"employee:edit",false);
    }

    /** 员工档案无单据状态机跳变，更新时同 manage 校验即可。 */
    @Override
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        requireWritable(ownerId,user,"employee:edit",true);
    }

    @Override
    public void requireCanSelectAvatar(UUID ownerId, AuthUser user) {
        requireWritable(ownerId,user,"employee:avatar_edit",true);
    }

    private boolean isSelf(UUID ownerId,AuthUser user) {
        UUID actor=user.getEmployeeId();
        return actor!=null && (ownerId.equals(actor)
                || employeeIdentities.canonicalEmployeeId(ownerId).equals(employeeIdentities.canonicalEmployeeId(actor)));
    }

    private void requireWritable(UUID ownerId,AuthUser user,String permission,boolean forUpdate) {
        requireStaff(user);
        if(ownerId==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"附件必须绑定员工");
        Employee employee=(forUpdate?employeeRepository.findByIdForUpdate(ownerId):employeeRepository.findById(ownerId))
                .orElseThrow(EmployeeAttachmentAccessPolicy::notFound);
        // Resigned but retained records remain maintainable. Deleted archive identities do not.
        if(employee.isDeleted() || !(user.isSuperAdmin() || user.getPermissions().contains(permission)))throw notFound();
    }

    private static void requireStaff(AuthUser user) {
        if(user==null || user.isVisitor() || user.isMustChangePassword())throw notFound();
    }

    private void requireEmployee(UUID ownerId) {
        if (ownerId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定员工");
        }
        // Historical reads retain the original owner; new writes use requireWritable.
        if (employeeRepository.findById(ownerId).isEmpty()) {
            throw notFound();
        }
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "员工不存在");
    }
}
