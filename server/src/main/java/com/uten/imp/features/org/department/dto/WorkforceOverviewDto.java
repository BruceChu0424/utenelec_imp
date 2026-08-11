package com.uten.imp.features.org.department.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 公司/部门人员概况。公司根节点与普通部门共用同一契约，统计范围始终包含所选节点的全部后代。
 */
public record WorkforceOverviewDto(
        UUID organizationId,
        String organizationName,
        String organizationLevel,
        LocalDate asOf,
        LocalDate periodStart,
        int periodMonths,
        long directCurrentEmployees,
        long currentEmployees,
        long activeEmployees,
        long probationEmployees,
        long onLeaveEmployees,
        long hiredEmployees,
        long rehiredEmployees,
        long departedEmployees,
        long transferInEmployees,
        long transferOutEmployees,
        long openingHeadcount,
        BigDecimal averageHeadcount,
        BigDecimal turnoverRatePct,
        long netChange,
        long descendantDepartmentCount,
        long contractOverdue,
        long contractExpiringIn30Days,
        long probationOverdue,
        long probationEndingIn30Days,
        boolean turnoverRateApproximate,
        boolean historyCoverageComplete,
        long missingHistoryRecords,
        String dataQualityNote) {
}
