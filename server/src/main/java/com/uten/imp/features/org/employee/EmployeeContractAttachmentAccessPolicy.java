package com.uten.imp.features.org.employee;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * 员工合同附件（ownerType=EMPLOYEE_CONTRACT，ownerId=contract.id）的对象级授权。
 * 通过合同归属的员工复用与 {@link EmployeeAttachmentAccessPolicy} 一致的判定：
 * 查看持 employee:pii:view（或本人；合同扫描件属 PII 级敏感材料，不随 employee:view 扩散）；
 * 管理持 employee:edit。拒绝一律 NOT_FOUND 防枚举。
 */
@Component
@RequiredArgsConstructor
public class EmployeeContractAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {

    public static final String OWNER_TYPE = "EMPLOYEE_CONTRACT";

    private final EmployeeContractRepository contractRepository;
    private final EmployeeRepository employeeRepository;

    @Override
    public String ownerType() {
        return OWNER_TYPE;
    }

    @Override
    public void requireCanView(UUID ownerId, AuthUser user) {
        UUID employeeId = resolveEmployeeId(ownerId);
        if (user.isSuperAdmin()
                || employeeId.equals(user.getEmployeeId())
                || user.getPermissions().contains("employee:pii:view")) {
            return;
        }
        throw notFound();
    }

    @Override
    public void requireCanManage(UUID ownerId, AuthUser user) {
        resolveEmployeeId(ownerId);
        if (user.isSuperAdmin() || user.getPermissions().contains("employee:edit")) {
            return;
        }
        throw notFound();
    }

    @Override
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        requireCanManage(ownerId, user);
    }

    private UUID resolveEmployeeId(UUID contractId) {
        if (contractId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定合同");
        }
        EmployeeContract c = contractRepository.findById(contractId)
                .orElseThrow(() -> notFound());
        // 合同可能挂在已软删员工下（历史）；返回其 employeeId 用于本人判定。
        return c.getEmployee().getId();
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "合同不存在");
    }
}
