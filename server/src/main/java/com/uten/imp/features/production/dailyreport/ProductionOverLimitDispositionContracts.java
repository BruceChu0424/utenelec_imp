package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class ProductionOverLimitDispositionContracts {
    private ProductionOverLimitDispositionContracts() {}

    /**
     * 超限产出处理：原因选填(2026-11-11 口径「弹窗原因不用必填」)。留空/不足 2 字在构造期
     * 归一为「未填写原因」——落库列 production_over_limit_decisions.reason 库级 CHECK
     * 要求 2-500 字，消费方直接取 {@code reason()} 落库。
     */
    public record DecisionRequest(@NotBlank String action,
            @Size(max=500) String reason,
            @NotNull @PositiveOrZero Long expectedVersion,
            @NotBlank @Size(min=8,max=128) String idempotencyKey) {
        public static final String DEFAULT_REASON = "未填写原因";
        public DecisionRequest {
            if (reason == null || reason.strip().length() < 2) {
                reason = DEFAULT_REASON;
            }
        }
    }

    public record DecisionView(String action,String reason,String decidedByName,OffsetDateTime decidedAt) {}

    public record View(UUID id,String status,long rowVersion,UUID reportId,String reportNo,
            UUID reportItemId,UUID outputBatchId,UUID sourceSegmentId,String segmentCode,
            UUID planId,String planNo,String goodsCode,String goodsName,String colorName,String unitName,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal plannedQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal allowedRate,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal actualBatchQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal withinAuthorizationQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal overLimitQty,String overLimitReason,
            OffsetDateTime createdAt,String decisionReason,String decidedByName,OffsetDateTime decidedAt,
            boolean canDecide,String blockingReason,List<DecisionView> decisionHistory) {}
}
