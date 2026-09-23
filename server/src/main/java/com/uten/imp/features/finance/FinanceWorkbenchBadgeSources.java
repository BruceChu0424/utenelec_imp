package com.uten.imp.features.finance;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionController;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalController;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 钱流审核队列的计数来源: 订货审批、IQC 不合格退回与贷项。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class FinanceWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final ProcurementFinanceApprovalController procurementApprovals;
    private final ProcurementIqcRejectionController iqcRejections;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("procurementApproval", () -> WorkbenchBadgeSources.numbers(procurementApprovals.count())),
                new Source("iqcRejection", () -> iqcRejectionFacts(iqcRejections.counts(null, null))));
    }

    /**
     * IQC 退回贷项: 端点原样字段 + {@code open} = 待退回 + 已登记退回 + 财务异常(仍需财务处理的案件,
     * 原前端模型 ProcurementIqcRejectionCounts.open 的口径, 现只在服务端算这一次)。
     */
    private static Map<String, Long> iqcRejectionFacts(ProcurementIqcRejectionContracts.CaseCounts counts) {
        Map<String, Long> facts = new LinkedHashMap<>(WorkbenchBadgeSources.numbers(counts));
        facts.put("open", counts.pendingReturn() + counts.returnRecorded() + counts.financeException());
        return facts;
    }
}
