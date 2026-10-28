package com.uten.imp.features.org.employee;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
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
    private static final Pattern EMPLOYEE_CODE=Pattern.compile("UT[0-9]{4}");
    private static final int COLLISION_LIMIT=1024;
    private final EntityManager em;
    private final MasterCodeService masterCodes;
    private final EmployeeRepository employees;

    /** The UUID is new; the release claim and employee INSERT must commit in this same transaction. */
    @Transactional(propagation=Propagation.MANDATORY)
    public String nextForNewEmployee(UUID newEmployeeId) {
        if(newEmployeeId==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"新员工工号分配缺少档案身份");
        Object released=em.createNativeQuery("SELECT public.fn_claim_next_released_employee_code(:employeeId)")
                .setParameter("employeeId",newEmployeeId).getSingleResult();
        if(released!=null) {
            String code=released.toString();
            if(!EMPLOYEE_CODE.matcher(code).matches() || "UT0000".equals(code) || employees.existsByCode(code)) {
                // Do not abandon a pending release claim and silently choose a second number.
                throw new ApiException(ErrorCode.CONFLICT,"已释放工号的状态发生变化，请刷新后重试");
            }
            return code;
        }
        for(int attempt=0;attempt<COLLISION_LIMIT;attempt++) {
            String code=masterCodes.nextCode(MasterCodePrefix.EMPLOYEE);
            if(!employees.existsByCode(code))return code;
        }
        throw new ApiException(ErrorCode.CONFLICT,"员工工号分配冲突，请核对编号预约后重试");
    }
}
