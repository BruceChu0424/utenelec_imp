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
 * 仓库与品质入库链的计数来源: 预计到货/到货异常、超量到货财务审批、待退回供应商、IQC 待检、产成品待点收、品质结果、
 * 委外出库(ADR-143: subcontractOutbound.count = 委外人员已提交、仓库未发出的领料草稿张数; 与待发料列表同一口径,
 * 同一仓库数据范围谓词, 所在仓 = 草稿发出仓)。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。仓库任务类来源传 null = 本人仓库数据范围
 * (ADR-149; 任务中心带 scopeWarehouseId 汇总时取所选仓), 与列表同一谓词。
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
                new Source("warehouseInboundExpectation", () -> WorkbenchBadgeSources.numbers(inbound.expectationCount(null))),
                new Source("warehouseArrivalException", () -> WorkbenchBadgeSources.numbers(inbound.arrivalExceptionCount(null))),
                new Source("financeArrivalException", () -> WorkbenchBadgeSources.numbers(financeArrivalExceptions.count())),
                new Source("purchaseSupplierReturn", () -> WorkbenchBadgeSources.numbers(supplierReturns.count("PURCHASE"))),
                new Source("subcontractSupplierReturn", () -> WorkbenchBadgeSources.numbers(supplierReturns.count("SUBCONTRACT"))),
                new Source("iqcPending", () -> WorkbenchBadgeSources.numbers(inspections.pendingCount())),
                new Source("finishedInbound", () -> WorkbenchBadgeSources.numbers(finishedInbound.count(null))),
                new Source("qualityResult", () -> WorkbenchBadgeSources.numbers(qualityResults.typeCounts(null))),
                new Source("subcontractOutbound", () -> WorkbenchBadgeSources.numbers(subcontractOutbound.taskCount(null))));
    }
}
