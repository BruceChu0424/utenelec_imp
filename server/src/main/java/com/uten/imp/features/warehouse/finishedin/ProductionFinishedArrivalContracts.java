package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
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

    /**
     * 一批实物的登记(ADR-148 / ADR-151 §5): 登记以「实物交接批」为单位——同一报工、同一产出批次、
     * 送入仓库的各份(需求 / 计划公共 / 实际超产)一个库位、一个实点数、一个称重, 由服务端展开到各份。
     */
    public record ArrivalLotRequest(
            @NotNull UUID lotId,
            /** 本批的实际入库仓库; 同一报工的不同批可以登记到不同仓库(按「报工 x 仓库」各成一个登记批次)。 */
            @NotNull UUID warehouseId,
            @NotBlank @Size(max = 100) String place,
            /** 先入库后质检时必填: 整批实点数, 必须等于本批报工合计; 原流程不填。 */
            BigDecimal countedQty,
            /**
             * 仓库登记时实称的整批净重(千克, 4 位小数; ADR-135 §3.2); 空或 0 = 没称。
             * 服务端按各份数量比例分摊(余数落在最后一份), 合格入库草稿再按放行数量从份上分摊。
             */
            @DecimalMin(value = "0", inclusive = true)
            @Digits(integer = 14, fraction = 4) BigDecimal weight) {
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
            /** 一行一批实物(ADR-148); 待登记视图只含还没登记的批, 已登记视图是该登记批次的批。 */
            List<ArrivalLotView> lots,
            UUID sheetId,
            String sheetNo,
            OffsetDateTime reversedAt,
            String reversalReason,
            boolean reversible,
            List<RegistrationBatchView> batches,
            /** 先入库后质检(V597)：本登记批次是否「合格自动点收」。 */
            boolean stockInBeforeInspection) {

        public ArrivalRegistrationView {
            lots = List.copyOf(lots);
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

    /**
     * 产成品入库登记的唯一命令(单张 = 1 个来源, 多选 = N 个来源; ADR-151 §5)。服务端按「报工 x 实际入库仓」
     * 分组, 每组一个登记批次, 同仓的登记批次合成一张品质检查单; 整个命令一个事务, 任一组失败整批回滚。
     * 幂等: 同一操作人 + 批量键 + 同一内容重放原结果; 每组用批量键派生的子键落库。
     */
    public record BatchArrivalRegistrationRequest(
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+",
                    message = "幂等键只能包含字母、数字或 ._:-")
            String idempotencyKey,
            @Valid
            @NotNull
            @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
            List<ArrivalLotRequest> lots,
            @Size(max = 500, message = "备注不能超过 500 个字符")
            String remark,
            /** 先入库后质检(V597)：整批一个口径，逐组落到各自的登记头上。 */
            Boolean stockInBeforeInspection) {

        public boolean stockInBeforeInspectionRequested() {
            return Boolean.TRUE.equals(stockInBeforeInspection);
        }
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

    /**
     * 一批实物(ADR-148): 批内各份的报工行、合计与按归属拆分(服务端算一次), 以及登记事实。
     * 库位、实点数、称重都是整批一个。
     */
    public record ArrivalLotView(
            UUID lotId,
            Integer lineNo,
            List<ArrivalLotMemberView> members,
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
            /** 本批报工合计(报工单位)。 */
            BigDecimal reportedQty,
            BigDecimal demandQty,
            BigDecimal publicQty,
            BigDecimal actualSurplusQty,
            /** 「需求 1000 · 实际超产 100」; 整批都是需求份时为空。 */
            String splitText,
            String place,
            String placeHint,
            UUID lastWarehouseId,
            String lastWarehouseName,
            /** 已登记批次: 先入库后质检时的整批实点数; 待登记与原流程为空。 */
            BigDecimal countedQty,
            /** 已登记批次: 登记时实称的整批净重(千克); 待登记与没称的批为空。 */
            BigDecimal weight,
            /**
             * 1 个报工单位 = 多少货品基本单位(报工行 unit_rate, 空按 1)。页面按
             * 报工数量 x unitRate 核对实称重量与换算按重量计的精确重量(ADR-135 §3.2)。
             */
            BigDecimal unitRate) {

        public ArrivalLotView {
            members = List.copyOf(members);
        }
    }

    /** 批内一份: 报工行 + 归属(DEMAND / PUBLIC / ACTUAL_SURPLUS)。 */
    public record ArrivalLotMemberView(
            UUID reportItemId,
            Integer lineNo,
            BigDecimal qty,
            int sliceRank,
            String kind) {
    }
}
