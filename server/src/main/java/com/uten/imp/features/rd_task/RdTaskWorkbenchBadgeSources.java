package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 工程研发部任务中心(待认领 / 已认领在办)的计数来源。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class RdTaskWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final RdTaskController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("rdTask", () -> WorkbenchBadgeSources.numbers(controller.count())));
    }
}
