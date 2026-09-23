package com.uten.imp.features.profilechange;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 员工资料变更待审(信息变更审核卡)的计数来源。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class ProfileChangeWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final ProfileChangeController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("profileReview", () -> WorkbenchBadgeSources.numbers(controller.pendingCount())));
    }
}
