package com.uten.imp.features.operations.workbench;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 履约任务台的计数来源: 采购任务中心、委外任务中心、仓库生产领料待领。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class FulfillmentWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final FulfillmentWorkbenchController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("purchaseTask", () -> WorkbenchBadgeSources.numbers(controller.purchaseCount())),
                new Source("subcontractTask", () -> WorkbenchBadgeSources.numbers(controller.subcontractCount())),
                new Source("productionDraw", () -> WorkbenchBadgeSources.numbers(controller.warehouseCount())));
    }
}
