package com.uten.imp.features.org.department;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.dto.WorkforceOverviewDto;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.UUID;

/** 部门人力概览服务：过去 {@value #PERIOD_MONTHS} 个月在册/入职/离职/转岗统计 + 离职率（按期初期末平均在册估算；流量不平衡或任职历史缺失时不显示并给出说明）。 */
@Service
@RequiredArgsConstructor
public class WorkforceOverviewService {

    static final int PERIOD_MONTHS = 12;

    private final DepartmentRepository departmentRepository;
    private final WorkforceOverviewQuery query;

    @Transactional(readOnly = true)
    public WorkforceOverviewDto overview(UUID organizationId) {
        Department organization = departmentRepository.findById(organizationId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "组织节点不存在"));
        LocalDate asOf = BusinessTime.today();
        LocalDate periodStart = asOf.minusMonths(PERIOD_MONTHS).plusDays(1);
        WorkforceOverviewQuery.Snapshot snapshot =
                query.load(organizationId, periodStart, asOf);
        return summarize(organization, snapshot, periodStart, asOf);
    }

    WorkforceOverviewDto summarize(
            Department organization,
            WorkforceOverviewQuery.Snapshot snapshot,
            LocalDate periodStart,
            LocalDate asOf) {
        long inflow = snapshot.hired() + snapshot.rehired() + snapshot.transferIn();
        long outflow = snapshot.departed() + snapshot.transferOut();
        long rawOpening = snapshot.current() - inflow + outflow;
        boolean flowBalanceValid = rawOpening >= 0;
        long opening = Math.max(0, rawOpening);
        BigDecimal average = BigDecimal.valueOf(opening + snapshot.current())
                .divide(BigDecimal.valueOf(2), 1, RoundingMode.HALF_UP);
        boolean historyComplete = snapshot.missingHistory() == 0 && flowBalanceValid;
        BigDecimal turnoverRate = !historyComplete || average.signum() == 0
                ? null
                : BigDecimal.valueOf(snapshot.departed() * 100)
                        .divide(average, 1, RoundingMode.HALF_UP);
        String qualityNote;
        if (!flowBalanceValid) {
            qualityNote = "任职事件流量与当前在册人数不一致，离职率暂不显示。";
        } else if (snapshot.missingHistory() > 0) {
            qualityNote = "有 " + snapshot.missingHistory()
                    + " 条任职生命周期记录缺失，离职率暂不显示。";
        } else {
            qualityNote = "离职率按期初与期末平均在册人数估算。";
        }

        return new WorkforceOverviewDto(
                organization.getId(),
                organization.getName(),
                organization.getLevel(),
                asOf,
                periodStart,
                PERIOD_MONTHS,
                snapshot.directCurrent(),
                snapshot.current(),
                snapshot.active(),
                snapshot.probation(),
                snapshot.onLeave(),
                snapshot.hired(),
                snapshot.rehired(),
                snapshot.departed(),
                snapshot.transferIn(),
                snapshot.transferOut(),
                opening,
                average,
                turnoverRate,
                snapshot.current() - opening,
                snapshot.descendantDepartments(),
                snapshot.contractOverdue(),
                snapshot.contractExpiring(),
                snapshot.probationOverdue(),
                snapshot.probationEnding(),
                true,
                historyComplete,
                snapshot.missingHistory(),
                qualityNote);
    }
}
