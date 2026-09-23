package com.uten.imp.features.stock.allocation;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 车间退料待仓库确认实收的计数来源。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class ProductionReturnWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final ProductionMaterialReturnRequestController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("productionReturn", () -> WorkbenchBadgeSources.numbers(controller.count())));
    }
}
