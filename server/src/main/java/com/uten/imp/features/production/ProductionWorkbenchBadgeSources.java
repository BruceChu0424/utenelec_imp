package com.uten.imp.features.production;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import com.uten.imp.features.production.execution.ProductionExecutionWorkbenchController;
import com.uten.imp.features.production.execution.ProductionWorkshopTaskController;
import com.uten.imp.features.production.quality.ProductionFqcInspectionController;
import com.uten.imp.features.production.schedule.ProductionScheduleController;

import java.util.List;

/**
 * 生产链的计数来源: 待排产、车间任务、进行中批次、FQC 待检。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class ProductionWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final ProductionScheduleController schedule;
    private final ProductionWorkshopTaskController workshopTasks;
    private final ProductionExecutionWorkbenchController executionWorkbench;
    private final ProductionFqcInspectionController fqcInspections;
    private final com.uten.imp.features.production.execution.ProductionOverproductionRateController overproductionRates;
    private final com.uten.imp.features.production.fulfillment.ProductionMaterialIncrementController materialIncrements;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("productionSchedule", () -> WorkbenchBadgeSources.numbers(schedule.pendingCount())),
                new Source("workshopTask", () -> WorkbenchBadgeSources.numbers(workshopTasks.count())),
                new Source("productionExecution", () -> WorkbenchBadgeSources.numbers(executionWorkbench.count())),
                new Source("fqcPending", () -> WorkbenchBadgeSources.numbers(fqcInspections.count())),
                new Source("productionOverproductionRate", () -> WorkbenchBadgeSources.numbers(overproductionRates.count())),
                new Source("productionMaterialIncrement", () -> WorkbenchBadgeSources.numbers(materialIncrements.count())));
    }
}
