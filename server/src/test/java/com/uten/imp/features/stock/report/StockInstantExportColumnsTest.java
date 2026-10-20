package com.uten.imp.features.stock.report;

import com.uten.imp.common.measure.WeightUnit;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * 即时库存导出列集必须覆盖页面表格列（2026-10-20：页面「合格待入库」列上线后
 * 导出列集漏了它——带该列的表格投影导出被「列不存在或不在可导出范围」整单拒绝）。
 */
class StockInstantExportColumnsTest {

    @Test
    void qualifiedPendingStockInColumnSitsRightAfterPendingQtyLikeThePage() {
        var columns = StockReportService.instantExportColumns(WeightUnit.KG, false);
        List<String> keys = columns.stream().map(c -> c.key()).toList();
        int pending = keys.indexOf("pendingQty");
        assertEquals("pendingStockInQty", keys.get(pending + 1), "合格待入库必须紧跟待检量（与页面列序一致）");
        assertEquals("合格待入库", columns.get(pending + 1).label());
    }
}
