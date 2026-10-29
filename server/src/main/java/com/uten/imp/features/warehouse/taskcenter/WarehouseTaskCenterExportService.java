package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.LegacyExportBudget;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 仓库任务中心「按筛选结果导出表格」（2026-10-29 用户批注）。
 *
 * <p>与列表接口共用同一查询服务（授权、仓库范围、状态/关键词/表头筛选与排序完全一致），
 * 仅去掉分页语义：按 100 行/页（列表接口的页大小上限）翻页收齐当前筛选的行，行数上限
 * 沿用系统设置「导出行数上限」并被同步导出预算（500 行）压顶。
 */
@Service
public class WarehouseTaskCenterExportService {
    private final WarehouseOutboundTaskCenterQueryService outbound;
    private final WarehouseInboundTaskCenterQueryService inbound;
    private final SystemSettingsService settings;

    public WarehouseTaskCenterExportService(WarehouseOutboundTaskCenterQueryService outbound,
            WarehouseInboundTaskCenterQueryService inbound, SystemSettingsService settings) {
        this.outbound = outbound;
        this.inbound = inbound;
        this.settings = settings;
    }

    public ExportPayload outbound(WarehouseTaskCenterContracts.Filter filter) {
        return collect(filter, true);
    }

    public ExportPayload inbound(WarehouseTaskCenterContracts.Filter filter) {
        return collect(filter, false);
    }

    private ExportPayload collect(WarehouseTaskCenterContracts.Filter filter, boolean outboundDirection) {
        int maxRows = LegacyExportBudget.maximumRows(settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS));
        List<Map<String, Object>> all = new ArrayList<>();
        int seen = 0;
        for (int page = 1; page <= 2000; page++) {
            LegacyExportBudget.checkpoint();
            WarehouseTaskCenterContracts.Filter paged = withPage(filter, page, 100);
            WarehouseTaskCenterContracts.Page result = outboundDirection
                    ? outbound.list(paged) : inbound.list(paged);
            if (page == 1) requireRows(maxRows, result.total());
            for (WarehouseTaskCenterContracts.Row row : result.items()) {
                all.add(valuesOf(row, outboundDirection));
            }
            seen += result.items().size();
            requireRows(maxRows, seen);
            if (result.items().size() < 100 || seen >= result.total()) {
                return new ExportPayload(columns(outboundDirection), all, seen);
            }
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "仓库任务导出翻页未收敛，请收窄筛选后重试");
    }

    private static void requireRows(int maxRows, long rows) {
        if (rows > maxRows) throw new ApiException(ErrorCode.VALIDATION_FAILED,
                "导出数据超过 " + maxRows + " 行上限，请收窄筛选条件或分批导出");
        LegacyExportBudget.requireRows(rows);
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
        columns.add(new ExportColumn("quantity", "数量", ExportColumn.QTY, 130d));
        columns.add(new ExportColumn("unitName", "单位", ExportColumn.TEXT, 80d));
        if (outboundDirection) {
            columns.add(new ExportColumn("productionOrderNo", "生产工单", ExportColumn.TEXT, 150d));
        }
        columns.add(new ExportColumn("sourceDocNo", "来源单据", ExportColumn.TEXT, 180d));
        columns.add(new ExportColumn("partyName", "客户 / 供应商 / 委外商", ExportColumn.TEXT, 200d));
        columns.add(new ExportColumn("warehouseName", "仓库", ExportColumn.TEXT, 180d));
        columns.add(new ExportColumn("businessDate", "业务日期", ExportColumn.DATE, 120d));
        columns.add(new ExportColumn("responsibleName", "负责人", ExportColumn.TEXT, 150d));
        columns.add(new ExportColumn("makerName", "制单人", ExportColumn.TEXT, 150d));
        return List.copyOf(columns);
    }

    private static Map<String, Object> valuesOf(WarehouseTaskCenterContracts.Row row, boolean outboundDirection) {
        WarehouseTaskCenterContracts.Line line = row.line();
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("status", row.statusLabel());
        values.put("billNo", row.billNo());
        values.put("goodsName", line == null ? null : line.goodsName());
        values.put("goodsCode", line == null ? null : line.goodsCode());
        values.put("colorName", line == null ? null : line.colorName());
        values.put("specification", line == null ? null : line.specification());
        values.put("quantity", line == null ? null : line.quantity());
        values.put("unitName", line == null ? null : line.unitName());
        if (outboundDirection) values.put("productionOrderNo", row.productionOrderNo());
        values.put("sourceDocNo", row.sourceDocNo());
        values.put("partyName", row.partyName());
        values.put("warehouseName", row.warehouseName());
        values.put("businessDate", row.businessDate() == null ? null : row.businessDate().toString());
        values.put("responsibleName", row.responsibleName());
        values.put("makerName", row.makerName());
        return values;
    }
}
