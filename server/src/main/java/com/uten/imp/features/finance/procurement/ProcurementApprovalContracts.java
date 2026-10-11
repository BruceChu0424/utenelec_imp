package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import com.uten.imp.common.finance.PartyOpenBalanceView;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
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

        public FinanceApproval readOnly() {
            return new FinanceApproval(caseId,status,attempt,version,assigneeUserId,assigneeEmployeeId,
                    assigneeName,rejectionReason,submittedAt,List.of());
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
     *
     * <p>V835（2026-10-10 用户口径）：采购/委外创建时不填汇率（订单表头默认 1），
     * 财务审批时填写当日汇率。exchangeRate 为选填的整批共用财务汇率
     * （&gt;0、≤6 位小数）；缺省视为 1。审批时填写的汇率落 case 新列
     * {@code finance_exchange_rate}，不回写订单表头（V438 商业冻结）。
     */
    public record BatchApprovalRequest(
            @NotEmpty @Size(max = 100) List<@Valid BatchDecisionItem> items,
            @Size(max = 500) String remark,
            @DecimalMin(value = "0", inclusive = false)
            @Digits(integer = 12, fraction = 6)
            BigDecimal exchangeRate) {

        /** 兼容旧调用（无财务汇率）：视为缺省。 */
        public BatchApprovalRequest(
                List<@Valid BatchDecisionItem> items, String remark) {
            this(items, remark, null);
        }
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
            /** 折合本币: V835 起 COALESCE(finance_total_local, amount_snapshot)——财务已定值优先, 未定回落提交快照。 */
            BigDecimal amount,
            /** ADR-128: 订货货币原币金额与币种名, 列表按「金额 币种」显示。 */
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal totalOriginal,
            String currencyName,
            String supplierName,
            String warehouseName,
            LocalDate expectedDate,
            int attempt,
            long version,
            UUID submittedByEmployeeId,
            String submittedByName,
            OffsetDateTime submittedAt,
            long changeCount,
            /** 提交快照里的订单表头汇率——待审 case 批量通过缺省汇率时即按它折算(已批→快照→1 缺省链)。 */
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal exchangeRate,
            /** 明细行数(jsonb_array_length), 旧快照无 items 时为 0。 */
            int lineCount,
            /** 货品摘要: 首个货品名, 多货品时「名称 等 N 种」; 旧快照缺失时 null。 */
            String goodsSummary,
            /** 允许超收/允许损耗% 摘要(采购取超收、委外取损耗): 全部行未填时 null。
             *  2026-10-10 口径修复：与审核详情同源读 COALESCE(display_snapshot,
             *  submission_snapshot)——委外 allowedLossPct 只在展示快照里。 */
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal toleranceMin,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal toleranceMax,
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
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal exchangeRate,
            /**
             * V835 财务审批汇率 = case.finance_exchange_rate（审批通过时财务填写的
             * 当日汇率）。与 {@link #exchangeRate}（提交快照里的订单表头汇率，创建时
             * 默认 1）分离。约定：本字段仅在审批通过后回填财务值；未批/驳回返回
             * null，前端拿到 null 用快照 exchangeRate 兜底展示。
             */
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal financeExchangeRate,
            String settlementMethodName,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal taxRate,
            String purchaserName,
            String makerName,
            LocalDate deliverDate,
            String remark,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal totalOriginal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal totalLocal,
            /** ADR-128: 供应商在本单币种下的应付 / 可抵贷项与预付 / 还差多少, 其它币种另列。 */
            PartyOpenBalanceView supplierBalance,
            int sourceApplicationCount,
            List<QtyChange> qtyChanges,
            List<ReviewLine> items,
            List<ReviewLine> previousItems,
            Map<String, Object> headerSnapshot,
            Map<String, Object> previousHeaderSnapshot,
            List<ReviewHistoryEntry> history) {
        public ApprovalReview {
            items = List.copyOf(items);
            previousItems = List.copyOf(previousItems);
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
            UUID orderItemId,
            int lineNo,
            UUID goodsId,
            UUID colorId,
            UUID sourceItemId,
            String goodsCode,
            String goodsName,
            String colorName,
            @JsonSerialize(using = ToStringSerializer.class) UUID unitId,
            String unitName,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal unitRate,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal qty,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal price,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal amountOriginal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal amountLocal,
            LocalDate deliverDate,
            String sourceDocNo,
            String currencyName,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal weight,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal giftQty,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal allowedLossPct,
            /** 采购允许超收百分比(ADR-144); 委外与未填为空。 */
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal allowedOverReceiptPct,
            String remark,
            String sourceApplicationNos,
            String sourceAllocations,
            UUID currencyId,
            boolean displaySnapshotComplete,
            List<com.uten.imp.common.columns.ExtraColumnSnapshot> extraColumns,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal totalAmountInput) {
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
