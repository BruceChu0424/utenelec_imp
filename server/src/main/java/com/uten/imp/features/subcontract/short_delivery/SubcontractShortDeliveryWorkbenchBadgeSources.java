package com.uten.imp.features.subcontract.short_delivery;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 委外回厂短交判定(待判定 / 容差内 / 分批等待)的计数来源。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class SubcontractShortDeliveryWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final SubcontractShortDeliveryController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("subcontractShortDelivery", () -> WorkbenchBadgeSources.numbers(controller.count())));
    }
}
