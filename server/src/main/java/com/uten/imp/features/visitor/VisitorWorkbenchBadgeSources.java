package com.uten.imp.features.visitor;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 访客两张卡的计数来源: HR 访客审批(待审 / 已批准待来访)与被访人「我的访客」(待确认 / 在办两半)。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class VisitorWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final VisitorApprovalController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("visitorApproval", () -> WorkbenchBadgeSources.numbers(controller.pendingCount())),
                new Source("visitorHost", () -> WorkbenchBadgeSources.numbers(controller.hostPendingCount())));
    }
}
