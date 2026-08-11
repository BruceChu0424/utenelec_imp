package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 员工报销域到财务域的单向记账端口。
 *
 * <p>端口位于基础层，只表达原子记账所需的最小稳定契约，不泄露任何
 * FinanceExpense 实体、Repository 或报销明细正文。
 */
public interface EmployeeClaimPostingPort {

    UUID postEmployeeClaim(EmployeeClaimPosting posting);

    record EmployeeClaimPosting(
            UUID claimId,
            LocalDate paymentDate,
            UUID accountId,
            UUID expenseStyleId,
            UUID departmentId,
            BigDecimal amount
    ) {
    }
}
