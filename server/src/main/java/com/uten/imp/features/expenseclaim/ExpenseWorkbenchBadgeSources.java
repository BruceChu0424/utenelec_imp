package com.uten.imp.features.expenseclaim;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 报销的计数来源: 本人草稿/驳回/处理中, 财务待审批/待付款(一次查询带回)。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class ExpenseWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final ExpenseClaimController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("expense", () -> WorkbenchBadgeSources.numbers(controller.counts())));
    }
}
