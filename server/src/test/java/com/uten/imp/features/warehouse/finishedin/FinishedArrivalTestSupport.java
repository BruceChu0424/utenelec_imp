package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalLotRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalLotView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationResult;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.RegisteredReportView;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Function;

/**
 * 测试里登记产成品入库的唯一入口(ADR-148 / ADR-151 §5)：页面只有一个批量命令，一行一批实物。
 * 给出报工行时，按服务端待登记视图找到它们所在的批(选中一份 = 整批)，每批一个库位；
 * 先入库后质检时整批实点 = 本批待登记合计。
 */
public final class FinishedArrivalTestSupport {

    private FinishedArrivalTestSupport() {
    }

    /** 一张报工全部待登记的批登记到一个仓、一个库位。 */
    public static RegisteredReportView registerAll(
            ProductionFinishedArrivalRegistrationService service, UUID reportId,
            String key, UUID warehouseId, String place, String remark, boolean preStock) {
        ArrivalRegistrationView pending = service.batchDetail(List.of(reportId)).getFirst();
        return single(register(service, key, warehouseId,
                pending.lots().stream().map(lot -> lot(lot, warehouseId, place, preStock)).toList(),
                remark, preStock), reportId, warehouseId);
    }

    /** 指定报工行所在的批(按报工行给库位；同批多行取第一行的库位)。 */
    public static RegisteredReportView registerItems(
            ProductionFinishedArrivalRegistrationService service, UUID reportId,
            String key, UUID warehouseId, Collection<UUID> reportItemIds,
            Function<UUID, String> placeOf, String remark, boolean preStock) {
        return single(register(service, key, warehouseId,
                lotsOf(service, reportId, warehouseId, reportItemIds, placeOf, preStock), remark, preStock),
                reportId, warehouseId);
    }

    /** 同上，所有批同一个库位。 */
    public static RegisteredReportView registerItems(
            ProductionFinishedArrivalRegistrationService service, UUID reportId,
            String key, UUID warehouseId, Collection<UUID> reportItemIds, String place) {
        return registerItems(service, reportId, key, warehouseId, reportItemIds, ignored -> place, null, false);
    }

    /** 选中的报工行所在的批(待登记视图里的批请求)。 */
    public static List<ArrivalLotRequest> lotsOf(
            ProductionFinishedArrivalRegistrationService service, UUID reportId, UUID warehouseId,
            Collection<UUID> reportItemIds, Function<UUID, String> placeOf, boolean preStock) {
        ArrivalRegistrationView pending = service.batchDetail(List.of(reportId)).getFirst();
        List<ArrivalLotRequest> lots = new ArrayList<>();
        for (ArrivalLotView lot : pending.lots()) {
            UUID selected = lot.members().stream().map(member -> member.reportItemId())
                    .filter(reportItemIds::contains).findFirst().orElse(null);
            if (selected != null) lots.add(lot(lot, warehouseId, placeOf.apply(selected), preStock));
        }
        if (lots.isEmpty()) throw new IllegalStateException("所选报工行没有待登记的批: " + reportItemIds);
        return lots;
    }

    public static ArrivalLotRequest lot(ArrivalLotView lot, UUID warehouseId, String place, boolean preStock) {
        return new ArrivalLotRequest(lot.lotId(), warehouseId, place,
                preStock ? lot.reportedQty() : null, null);
    }

    public static BatchArrivalRegistrationResult register(
            ProductionFinishedArrivalRegistrationService service, String key, UUID warehouseId,
            List<ArrivalLotRequest> lots, String remark, boolean preStock) {
        return service.batchRegister(new BatchArrivalRegistrationRequest(key, lots, remark, preStock ? Boolean.TRUE : null));
    }

    /** 报工行 -> 本批待登记合计(先入库后质检用)。 */
    public static Map<UUID, BigDecimal> lotTotals(ArrivalRegistrationView view) {
        java.util.LinkedHashMap<UUID, BigDecimal> result = new java.util.LinkedHashMap<>();
        for (ArrivalLotView lot : view.lots()) {
            lot.members().forEach(member -> result.put(member.reportItemId(), lot.reportedQty()));
        }
        return result;
    }

    private static RegisteredReportView single(BatchArrivalRegistrationResult result, UUID reportId, UUID warehouseId) {
        return result.reports().stream()
                .filter(report -> report.reportId().equals(reportId) && report.warehouseId().equals(warehouseId))
                .findFirst().orElseThrow();
    }
}
