package com.uten.imp.features.warehouse;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import com.uten.imp.features.warehouse.finishedin.ProductionFinishedInboundTaskController;
import com.uten.imp.features.warehouse.inbound.FinanceProcurementArrivalExceptionController;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalExceptionController;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionController;
import com.uten.imp.features.warehouse.inbound.WarehouseInboundController;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultController;
import com.uten.imp.features.warehouse.outbound.WarehouseSubcontractOutboundController;

import java.util.List;

/**
 * 仓库与品质入库链的计数来源: 预计到货/到货异常、超量到货财务审批、待退回供应商、IQC 待检、产成品待点收、品质结果、委外待出仓。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class WarehouseWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final WarehouseInboundController inbound;
    private final FinanceProcurementArrivalExceptionController financeArrivalExceptions;
    private final ProcurementArrivalExceptionController supplierReturns;
    private final ProcurementInspectionController inspections;
    private final ProductionFinishedInboundTaskController finishedInbound;
    private final WarehouseQualityResultController qualityResults;
    private final WarehouseSubcontractOutboundController subcontractOutbound;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("warehouseInboundExpectation", () -> WorkbenchBadgeSources.numbers(inbound.expectationCount())),
                new Source("warehouseArrivalException", () -> WorkbenchBadgeSources.numbers(inbound.arrivalExceptionCount())),
                new Source("financeArrivalException", () -> WorkbenchBadgeSources.numbers(financeArrivalExceptions.count())),
                new Source("purchaseSupplierReturn", () -> WorkbenchBadgeSources.numbers(supplierReturns.count("PURCHASE"))),
                new Source("subcontractSupplierReturn", () -> WorkbenchBadgeSources.numbers(supplierReturns.count("SUBCONTRACT"))),
                new Source("iqcPending", () -> WorkbenchBadgeSources.numbers(inspections.pendingCount())),
                new Source("finishedInbound", () -> WorkbenchBadgeSources.numbers(finishedInbound.count())),
                new Source("qualityResult", () -> WorkbenchBadgeSources.numbers(qualityResults.typeCounts())),
                new Source("subcontractOutbound", () -> WorkbenchBadgeSources.numbers(subcontractOutbound.taskCount())));
    }
}
