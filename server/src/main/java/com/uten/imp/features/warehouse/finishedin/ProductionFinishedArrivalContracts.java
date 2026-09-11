package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** HTTP contracts for warehouse registration before production FQC. */
public final class ProductionFinishedArrivalContracts {

    private ProductionFinishedArrivalContracts() {
    }

    public record ArrivalRegistrationRequest(
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+",
                    message = "幂等键只能包含字母、数字或 ._:-")
            String idempotencyKey,
            @NotNull UUID warehouseId,
            @Valid
            @NotNull
            @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
            List<ArrivalRegistrationItemRequest> items,
            @Size(max = 500, message = "备注不能超过 500 个字符")
            String remark) {
    }

    public record ArrivalRegistrationItemRequest(
            @NotNull UUID reportItemId,
            @NotBlank @Size(max = 100) String place) {
    }

    public record ArrivalRegistrationView(
            UUID registrationId,
            boolean registered,
            UUID reportId,
            String reportNo,
            LocalDate reportDate,
            UUID departmentId,
            String workshopName,
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            UUID receiverEmployeeId,
            String receiverName,
            String remark,
            OffsetDateTime registeredAt,
            List<ArrivalRegistrationItemView> items,
            UUID sheetId,
            String sheetNo,
            OffsetDateTime reversedAt,
            String reversalReason,
            boolean reversible,
            List<RegistrationBatchView> batches) {

        public ArrivalRegistrationView {
            items = List.copyOf(items);
            batches = batches == null ? List.of() : List.copyOf(batches);
        }
    }

    /**
     * 同一报工的每个登记批次（V469 分批 + V548 撤回态）：已登记视图列出全部批次，
     * 供页面按批次显示检查单号与「撤回登记（仅品质未处理）」。
     */
    public record RegistrationBatchView(
            UUID registrationId,
            UUID warehouseId,
            String warehouseName,
            String receiverName,
            String remark,
            OffsetDateTime registeredAt,
            int itemCount,
            UUID sheetId,
            String sheetNo,
            OffsetDateTime reversedAt,
            String reversalReason,
            boolean reversible) {
    }

    /** V548 登记撤回请求：原因必填（2–500 字）+ 稳定幂等键。 */
    public record ArrivalRegistrationReversalRequest(
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+",
                    message = "幂等键只能包含字母、数字或 ._:-")
            String idempotencyKey,
            @NotBlank
            @Size(min = 2, max = 500, message = "撤回原因必须为 2 到 500 个字符")
            String reason) {
    }

    /** V547 本次登记命令生成的品质检查单（每个成品仓一张）。 */
    public record InspectionSheetSummaryView(
            UUID sheetId,
            String sheetNo,
            UUID warehouseId,
            String warehouseName,
            int itemCount) {
    }

    /** Warehouse-scoped suggestions for every immutable report line. */
    public record PlaceSuggestionsView(
            List<PlaceSuggestionItemView> items) {

        public PlaceSuggestionsView {
            items = List.copyOf(items);
        }
    }

    public record PlaceSuggestionItemView(
            UUID reportItemId,
            String place,
            String source) {
    }

    /** Result of the explicit, registration-derived remember action. */
    public record RememberPlacesResult(
            int remembered,
            int unchanged,
            int ambiguous,
            List<String> warnings) {

        public RememberPlacesResult {
            warnings = List.copyOf(warnings);
        }
    }

    /** 多张报工单一次性汇总登记：每张可提交其待办行的非空子集并逐行创建 FQC。 */
    public record BatchArrivalRegistrationRequest(
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+",
                    message = "幂等键只能包含字母、数字或 ._:-")
            String idempotencyKey,
            @Valid
            @NotNull
            @Size(min = 1, max = 50)
            List<BatchReportRegistrationRequest> reports,
            @Size(max = 500, message = "备注不能超过 500 个字符")
            String remark) {
    }

    public record BatchReportRegistrationRequest(
            @NotNull UUID reportId,
            @NotNull UUID warehouseId,
            @Valid
            @NotNull
            @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
            List<ArrivalRegistrationItemRequest> items) {
    }

    public record BatchArrivalRegistrationResult(
            int registeredCount,
            List<RegisteredReportView> reports,
            List<InspectionSheetSummaryView> sheets) {

        public BatchArrivalRegistrationResult {
            reports = List.copyOf(reports);
            sheets = sheets == null ? List.of() : List.copyOf(sheets);
        }
    }

    public record RegisteredReportView(
            UUID registrationId,
            UUID reportId,
            String reportNo,
            UUID warehouseId,
            String warehouseName,
            UUID sheetId,
            String sheetNo) {
    }

    /** 批量登记后的库位记忆汇总（逐单聚合 remembered/unchanged/ambiguous 与告警）。 */
    public record BatchRememberPlacesResult(
            int remembered,
            int unchanged,
            int ambiguous,
            List<String> warnings) {

        public BatchRememberPlacesResult {
            warnings = List.copyOf(warnings);
        }
    }

    /** 当前用户最近一次成品送检登记所用的成品仓（下次进入自动预选）。 */
    public record LastWarehouseView(
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            OffsetDateTime usedAt) {
    }

    public record ArrivalRegistrationItemView(
            UUID reportItemId,
            Integer lineNo,
            UUID planItemId,
            UUID executionSegmentId,
            UUID planId,
            String planNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal reportedQty,
            String place,
            String placeHint,
            UUID lastWarehouseId,
            String lastWarehouseName) {
    }
}
