package com.uten.imp.features.sales;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import com.uten.imp.features.sales.order.SalesOrderController;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmController;
import com.uten.imp.features.sales.shipment.SalesShipmentController;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundController;

import java.util.List;

/**
 * 销售链的计数来源: 订单进度阶段、订货单财务确认、出货财务审核、仓库销售出库。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class SalesWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final SalesOrderController orders;
    private final SalesOrderFinanceConfirmController financeConfirmation;
    private final SalesShipmentController shipments;
    private final WarehouseSalesOutboundController warehouseOutbound;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("salesStage", () -> WorkbenchBadgeSources.numbers(orders.progressStageCounts())),
                new Source("salesOrderFinance", () -> WorkbenchBadgeSources.numbers(financeConfirmation.pendingCount(null))),
                new Source("shipmentFinance", () -> WorkbenchBadgeSources.numbers(shipments.pendingFinanceCount())),
                new Source("warehouseSalesOutbound", () -> WorkbenchBadgeSources.numbers(warehouseOutbound.counts())));
    }
}
