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
    private final EmployeeAttachmentAccessPolicy employeePolicy;

    @Override
    public String ownerType() {
        return OWNER_TYPE;
    }

    @Override
    public void requireCanView(UUID ownerId, AuthUser user) {
        authorize(ownerId,user,false,false);
    }

    @Override
    public void requireCanManage(UUID ownerId, AuthUser user) {
        authorize(ownerId,user,true,false);
    }

    @Override
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        authorize(ownerId,user,true,true);
    }

    private void authorize(UUID contractId,AuthUser user,boolean write,boolean forUpdate) {
        UUID employee=resolveEmployeeId(contractId,forUpdate);
        try {
            if(!write)employeePolicy.requireCanView(employee,user);
            else if(forUpdate)employeePolicy.requireCanManageForUpdate(employee,user);
            else employeePolicy.requireCanManage(employee,user);
        } catch(ApiException denied) {
            if(denied.getCode()==ErrorCode.NOT_FOUND)throw notFound();
            throw denied;
        }
    }

    private UUID resolveEmployeeId(UUID contractId,boolean forUpdate) {
        if (contractId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定合同");
        }
        EmployeeContract c = (forUpdate?contractRepository.findByIdForUpdate(contractId):contractRepository.findById(contractId))
                .orElseThrow(() -> notFound());
        // 合同可能挂在已软删员工下（历史）；返回其 employeeId 用于本人判定。
        return c.getEmployee().getId();
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "合同不存在");
    }
}
