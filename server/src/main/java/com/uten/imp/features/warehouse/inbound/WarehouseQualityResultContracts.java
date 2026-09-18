package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockedLocation;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 品质部检查结果合并页（原 IQC 合格待入库 + IQC 不合格实物退回）的无金额契约。
 * 每行聚合到收货单：作业状态把「等待检查结果 / 全部合格待入库 / 部分合格 / 全部不合格需退回 /
 * 已完结」统一成一个口径；切片与退回明细由详情接口提供。
 */
public final class WarehouseQualityResultContracts {

    private WarehouseQualityResultContracts() {
    }

    public record TaskSummary(
            String workStatus,
            String receiptType,
            @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            String billNo,
            LocalDate billDate,
            @JsonSerialize(using = ToStringSerializer.class) UUID supplierId,
            String supplierName,
            @JsonSerialize(using = ToStringSerializer.class) UUID warehouseId,
            String warehouseName,
            long goodsLineCount,
            long passedLineCount,
            long failedLineCount,
            long openItemCount,
            long pendingSliceCount,
            long pendingReturnCount,
            OffsetDateTime lastActivityAt,
            /** 先入库后检(V596)：仍在等结论且已上架的明细行数(>0 表示实物已在库位、合格自动转正)。 */
            long preStockedLineCount) {
    }

    public record TaskDetail(
            String workStatus,
            String receiptType,
            @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            String billNo,
            LocalDate billDate,
            @JsonSerialize(using = ToStringSerializer.class) UUID supplierId,
            String supplierName,
            @JsonSerialize(using = ToStringSerializer.class) UUID warehouseId,
            String warehouseName,
            String qualityStatus,
            long goodsLineCount,
            long passedLineCount,
            long failedLineCount,
            long openItemCount,
            long pendingSliceCount,
            long pendingReturnCount,
            boolean completed,
            boolean containsOwnRelease,
            List<String> allowedActions,
            List<InspectionLineItem> lines,
            List<ProcurementIqcStockInContracts.ReleasedSlice> items,
            List<ProcurementIqcStockInContracts.StockInHistoryItem> history,
            List<RejectionCaseItem> rejections,
            /** 先入库后检(V596)：仍在等结论且已上架的明细行数。 */
            long preStockedLineCount) {

        /** 动作码：先把待检明细上架(需 warehouse_iqc_stock_in:before_inspection)。 */
        public static final String ACTION_PRE_STOCK_IN = "PRE_STOCK_IN";

        public TaskDetail {
            allowedActions = allowedActions == null ? List.of() : List.copyOf(allowedActions);
            lines = lines == null ? List.of() : List.copyOf(lines);
            items = items == null ? List.of() : List.copyOf(items);
            history = history == null ? List.of() : List.copyOf(history);
            rejections = rejections == null ? List.of() : List.copyOf(rejections);
        }
    }

    /**
     * 检查结果明细行（详情页逐货品行的判定数据）：合格 / 不合格 / 部分合格 /
     * 待检由前端按 数量与行状态 推导，服务端不下结论，避免与作业状态口径耦合。
     */
    public record InspectionLineItem(
            @JsonSerialize(using = ToStringSerializer.class) UUID inspectionItemId,
            @JsonSerialize(using = ToStringSerializer.class) UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            @JsonSerialize(using = ToStringSerializer.class) UUID unitId,
            String unitName,
            String lineStatus,
            BigDecimal receivedBaseQty,
            BigDecimal passedBaseQty,
            BigDecimal failedBaseQty,
            BigDecimal warehouseStockedBaseQty,
            BigDecimal pendingStockBaseQty,
            @JsonSerialize(using = ToStringSerializer.class) UUID warehouseId,
            String warehouseName,
            /** 先入库后检(V596)：该行已上架的实际仓/库位；null=未上架(原流程)。 */
            PreStockedLocation preStocked,
            /** 建议库位(仓库×货品×颜色学习偏好，回落货品主档)；先入库上架页预填用。 */
            String placeHint) {

        /** 仍等结论且未上架的行可被「先入库上架」。 */
        public boolean preStockable() {
            return preStocked == null && "PENDING".equals(lineStatus)
                    && (passedBaseQty == null || passedBaseQty.signum() == 0)
                    && (failedBaseQty == null || failedBaseQty.signum() == 0);
        }
    }

    /** 检查不合格产生的实物退回任务（V440 拒收案件在仓库侧的投影）。 */
    public record RejectionCaseItem(
            @JsonSerialize(using = ToStringSerializer.class) UUID id,
            @JsonSerialize(using = ToStringSerializer.class) UUID inspectionItemId,
            @JsonSerialize(using = ToStringSerializer.class) UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal failedQty,
            String physicalStatus,
            String returnReference,
            LocalDate returnDate,
            String returnNote,
            String returnRecordedByName,
            OffsetDateTime returnRecordedAt,
            long rowVersion,
            boolean canRecordReturn,
            /** 先入库后检(V596)：不合格实物当前所在的上架仓/库位，仓库据此取货退回；null=未上架。 */
            PreStockedLocation preStocked) {
    }
}
