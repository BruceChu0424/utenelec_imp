package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.export.LegacyExportBudget;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 仓库任务中心「按筛选结果导出表格」（2026-10-29 用户批注）。
 *
 * <p>与列表接口共用同一查询服务（授权、仓库范围、状态/关键词/表头筛选与排序完全一致），
 * 在同一只读快照中按 100 行的内部批次收齐当前筛选的全部结果，流式写入同一个文件。
 */
@Service
@Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ,
        timeout = com.uten.imp.common.export.ExportTransactions.TIMEOUT_SECONDS)
public class WarehouseTaskCenterExportService {
    private final WarehouseOutboundTaskCenterQueryService outbound;
    private final WarehouseInboundTaskCenterQueryService inbound;

    public WarehouseTaskCenterExportService(WarehouseOutboundTaskCenterQueryService outbound,
            WarehouseInboundTaskCenterQueryService inbound) {
        this.outbound = outbound;
        this.inbound = inbound;
    }

    public ExportPayload outbound(WarehouseTaskCenterContracts.Filter filter) {
        return collect(filter, true);
    }

    public ExportPayload inbound(WarehouseTaskCenterContracts.Filter filter) {
        return collect(filter, false);
    }

    private ExportPayload collect(WarehouseTaskCenterContracts.Filter filter, boolean outboundDirection) {
        var sink = ExportPageSink.current();
        List<ExportColumn> columns = columns(outboundDirection).stream()
                .filter(column -> !outboundDirection || "DRAW".equals(filter.source()) || "ALL".equals(filter.source())
                        || !"productionOrderNo".equals(column.key())).toList();
        List<Map<String, Object>> all = sink == null ? new ArrayList<>() : null;
        int seen = 0;
        long expected = -1;
        for (int page = 1; ; page = Math.incrementExact(page)) {
            LegacyExportBudget.checkpoint();
            WarehouseTaskCenterContracts.Filter paged = withPage(filter, page, 100);
            WarehouseTaskCenterContracts.Page result = outboundDirection
                    ? outbound.list(paged,false) : inbound.list(paged,false);
            if (result.page() != page || result.size() != 100 || result.items().size() > 100)
                throw new IllegalStateException("Warehouse task export pagination changed");
            if (expected < 0) {
                expected = result.total();
                if (expected < 0) throw new IllegalStateException("Warehouse task export requires its initial count");
            } else if (result.total() != expected) {
                throw new IllegalStateException("Warehouse task export source count changed");
            }
            List<Map<String, Object>> rows = result.items().stream().map(row -> valuesOf(row, outboundDirection)).toList();
            seen = Math.addExact(seen, rows.size());
            LegacyExportBudget.requireRows(seen);
            if (seen > expected || rows.size() < 100 && seen < expected)
                throw new IllegalStateException("Warehouse task export source is incomplete");
            if (sink == null) all.addAll(rows);
            else sink.accept(new ExportPayload(columns, rows, seen));
            if (seen == expected) return new ExportPayload(columns, sink == null ? List.copyOf(all) : List.of(), seen);
        }
    }

    static WarehouseTaskCenterContracts.Filter withPage(WarehouseTaskCenterContracts.Filter filter, int page, int size) {
        return new WarehouseTaskCenterContracts.Filter(filter.source(), filter.status(), filter.keyword(),
                filter.billNo(), filter.dateFrom(), filter.dateTo(), filter.scopeWarehouseId(), page, size,
                filter.sort(), filter.order(), filter.view(), filter.columnSearch());
    }

    /** 列键与前端任务中心表格列一致（生产工单仅出库方向），供列投影白名单校验。 */
    static List<ExportColumn> columns(boolean outboundDirection) {
        List<ExportColumn> columns = new ArrayList<>();
        columns.add(new ExportColumn("status", "状态", ExportColumn.TEXT, 210d));
        columns.add(new ExportColumn("billNo", "单据 / 任务单号", ExportColumn.TEXT, 180d));
        columns.add(new ExportColumn("goodsName", "货品名称", ExportColumn.TEXT, 200d));
        columns.add(new ExportColumn("goodsCode", "货品编码", ExportColumn.TEXT, 150d));
        columns.add(new ExportColumn("colorName", "颜色", ExportColumn.TEXT, 100d));
        columns.add(new ExportColumn("specification", "规格", ExportColumn.TEXT, 140d));
        columns.add(new ExportColumn("quantity", outboundDirection ? "数量" : "申报 / 单据数量", ExportColumn.QTY, 150d));
        columns.add(new ExportColumn("unitName", "单位", ExportColumn.TEXT, 80d));
        if (!outboundDirection) {
            columns.add(new ExportColumn("stockedQty","已入库",ExportColumn.QTY,140d));
            columns.add(new ExportColumn("pendingStockInQty","合格待入库",ExportColumn.QTY,140d));
            columns.add(new ExportColumn("pendingReturnQty","剩余待退回",ExportColumn.QTY,140d));
            columns.add(new ExportColumn("nextStep","下一步",ExportColumn.TEXT,270d));
        }
        if (outboundDirection) {
            columns.add(new ExportColumn("productionOrderNo", "生产工单", ExportColumn.TEXT, 150d));
        }
        columns.add(new ExportColumn("warehouseName", "仓库", ExportColumn.TEXT, 180d));
        if (outboundDirection) columns.add(new ExportColumn("stockPlace", "库位号", ExportColumn.TEXT, 140d));
        columns.add(new ExportColumn("businessDate", "业务日期", ExportColumn.DATE, 120d));
        columns.add(new ExportColumn("responsibleName", "负责人", ExportColumn.TEXT, 150d));
        columns.add(new ExportColumn("makerName", "制单人", ExportColumn.TEXT, 150d));
        return List.copyOf(columns);
    }

    private static Map<String, Object> valuesOf(WarehouseTaskCenterContracts.Row row, boolean outboundDirection) {
        WarehouseTaskCenterContracts.Line line = row.line();
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("rowKey", row.rowKey());
        values.put("status", row.statusLabel());
        values.put("billNo", row.billNo());
        values.put("goodsName", line == null ? null : line.goodsName());
        values.put("goodsCode", line == null ? null : line.goodsCode());
        values.put("colorName", line == null ? null : line.colorName());
        values.put("specification", line == null ? null : line.specification());
        values.put("quantity", line == null ? null : line.quantity());
        values.put("unitName", line == null ? null : line.unitName());
        if (outboundDirection) values.put("productionOrderNo", row.productionOrderNo());
        if (!outboundDirection) {
            for (String key:List.of("stockedQty","pendingStockInQty","pendingReturnQty")) {
                Object value=row.actionData().get(key);
                values.put(key,value==null?null:new java.math.BigDecimal(value.toString()));
            }
            values.put("nextStep",row.actionData().get("nextStep"));
        }
        values.put("sourceDocNo", row.sourceDocNo());
        values.put("partyName", row.partyName());
        values.put("warehouseName", row.warehouseName());
        if (outboundDirection) values.put("stockPlace", line == null ? null : line.stockPlace());
        values.put("businessDate", row.businessDate() == null ? null : row.businessDate().toString());
        values.put("responsibleName", row.responsibleName());
        values.put("makerName", row.makerName());
        return values;
    }
}
