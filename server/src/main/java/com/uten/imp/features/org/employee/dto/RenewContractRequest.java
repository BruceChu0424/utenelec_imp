package com.uten.imp.features.org.employee.dto;

import java.time.LocalDate;

/**
 * 续签/补录合同。contractType 缺省 fixed；startDate 缺省今天；endDate 为 null 表示无固定期限。
 * signOrder 由服务端取该员工现有合同最大序号 +1 自动分配。
 */
public record RenewContractRequest(
        String contractType,
        LocalDate startDate,
        LocalDate endDate,
        Integer probationMonths) {
}
