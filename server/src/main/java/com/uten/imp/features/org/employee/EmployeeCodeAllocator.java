package com.uten.imp.features.org.employee;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;
import java.util.regex.Pattern;

/** Employee-only allocation; other master and document namespaces retain their lifetime rules. */
@Service
@RequiredArgsConstructor
public class EmployeeCodeAllocator {
    private static final Pattern EMPLOYEE_CODE=Pattern.compile("[0-9]{6}");
    private static final int COLLISION_LIMIT=1024;
    private final MasterCodeService masterCodes;
    private final EmployeeRepository employees;

    /** Fixed six-digit numbers; retired UT numbers are historical evidence, never new allocations. */
    @Transactional(propagation=Propagation.MANDATORY)
    public String nextForNewEmployee(UUID newEmployeeId) {
        if(newEmployeeId==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"新员工工号分配缺少档案身份");
        for(int attempt=0;attempt<COLLISION_LIMIT;attempt++) {
            String code=masterCodes.nextCode(MasterCodePrefix.EMPLOYEE);
            if (code == null || !EMPLOYEE_CODE.matcher(code).matches() || code.compareTo("000003") < 0) {
                throw new ApiException(ErrorCode.CONFLICT,"员工工号必须为六位数字，前两号保留给创始人");
            }
            if(!employees.existsByCode(code))return code;
        }
        throw new ApiException(ErrorCode.CONFLICT,"员工工号分配冲突，请核对编号预约后重试");
    }
}
