package com.uten.imp.features.org.hrtask;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * HR 任务中心(今日转正/逾期转正/生日/周年)的计数来源。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class HrTaskWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final HrTaskController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("hrTask", () -> WorkbenchBadgeSources.numbers(controller.count())));
    }
}
