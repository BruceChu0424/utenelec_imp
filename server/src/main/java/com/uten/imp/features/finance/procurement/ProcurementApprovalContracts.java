package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class ProcurementApprovalContracts {

    private ProcurementApprovalContracts() {
    }

    public record FinanceApproval(
            UUID caseId,
            String status,
            int attempt,
            long version,
            UUID assigneeUserId,
            UUID assigneeEmployeeId,
            String assigneeName,
            String rejectionReason,
            OffsetDateTime submittedAt,
            List<String> allowedActions) {
        public FinanceApproval {
            allowedActions = List.copyOf(allowedActions);
        }
    }

    /** 精确绑定一次待审 case，避免驳回重提后相同版本号误命中新 attempt。 */
    public record BatchDecisionItem(
            @NotNull UUID caseId,
            @NotNull @Min(1) Long expectedVersion,UUID expectedClaimId) {
        public BatchDecisionItem(UUID caseId,Long expectedVersion) { this(caseId,expectedVersion,null); }
    }

    /**
     * 批量通过请求。remark 为单笔详情页提供的选填审批备注（≤500 字），
     * 写入审批事件快照留痕；列表批量操作可省略。
     */
    public record BatchApprovalRequest(
            @NotEmpty @Size(max = 100) List<@Valid BatchDecisionItem> items,
            @Size(max = 500) String remark) {
    }

    public record BatchRejectionRequest(
            @NotEmpty @Size(max = 100) List<@Valid BatchDecisionItem> items,
            @NotBlank @Size(max = 1000) String reason) {
    }

    public record BatchDecisionResponse(
            int processed,
            List<FinanceApproval> decisions) {
        public BatchDecisionResponse {
            decisions = List.copyOf(decisions);
        }
    }

    public record ApprovalTask(
            UUID caseId,
            String orderType,
            UUID orderId,
            String billNo,
            BigDecimal amount,
            String supplierName,
            String warehouseName,
            LocalDate expectedDate,
            int attempt,
            long version,
            UUID submittedByEmployeeId,
            String submittedByName,
            OffsetDateTime submittedAt,
            long changeCount,
            List<String> allowedActions) {
    }

    /**
     * V486 批准后改量请求：逐行新数量（old→new 差异行）。仅已批准订单可用，
     * 服务端校验下游锁定量后立即生效并自动创建财务复核 case。
     */
    public record OrderQtyChangeRequest(
            @NotEmpty List<@Valid OrderQtyChangeItem> items) {
    }

    public record OrderQtyChangeItem(
            @NotNull UUID orderItemId,
            @NotNull @DecimalMin(value = "0", inclusive = false)
            BigDecimal newQty) {
    }

    /**
     * 审核详情（财务专用视图，与采购/委外业务详情页分离）：审批任务身份 +
     * 订单头商业事实 + 供应商应付快照 + 明细 + 审批历史。allowedActions 仅在
     * case 仍为 PENDING 时按当前审核员实时资格计算，否则为空列表。
     */
    public record ApprovalReview(
            UUID caseId,
            String orderType,
            UUID orderId,
            String billNo,
            String status,
            int attempt,
            long version,
            List<String> allowedActions,
            String submittedByName,
            OffsetDateTime submittedAt,
            LocalDate billDate,
            String supplierName,
            String supplierCode,
            String warehouseName,
            String currencyName,
            BigDecimal exchangeRate,
            String settlementMethodName,
            BigDecimal taxRate,
            String purchaserName,
            String makerName,
            LocalDate deliverDate,
            String remark,
            BigDecimal totalOriginal,
            BigDecimal totalLocal,
            BigDecimal supplierApBalance,
            int sourceApplicationCount,
            List<QtyChange> qtyChanges,
            List<ReviewLine> items,
            List<ReviewHistoryEntry> history) {
        public ApprovalReview {
            items = List.copyOf(items);
            history = List.copyOf(history);
            allowedActions = List.copyOf(allowedActions);
            qtyChanges = List.copyOf(qtyChanges);
        }
    }

    /**
     * V486 修改清单（以前→现在）：本 case 关联的改量事实账行；首次提交审批
     * 的普通 case 恒为空列表。
     */
    public record QtyChange(
            UUID orderItemId,
            int lineNo,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal oldQty,
            BigDecimal newQty,
            String changedByName,
            OffsetDateTime changedAt) {
    }

    /**
     * 审核明细行。{@code unitId} 供前端「合计数量」按单位分组用（不同单位的数量
     * 绝不相加），{@code unitName} 只作显示标签。
     */
    public record ReviewLine(
            int lineNo,
            String goodsCode,
            String goodsName,
            String colorName,
            @JsonSerialize(using = ToStringSerializer.class) UUID unitId,
            String unitName,
            BigDecimal unitRate,
            BigDecimal qty,
            BigDecimal price,
            BigDecimal amountOriginal,
            BigDecimal amountLocal,
            LocalDate deliverDate,
            String sourceDocNo) {
    }

    /** 审批历史：按提交轮次展示 提交/通过/驳回 事件、操作人与原因。 */
    public record ReviewHistoryEntry(
            int attempt,
            String eventType,
            String actorName,
            OffsetDateTime occurredAt,
            String reason) {
    }
}
