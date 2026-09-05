package com.uten.imp.features.stock.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * DRAW 领料单分轮出库/取消出库请求（取消沿兼容 reverse API）。
 * 每行：itemId + 本次数量（出库须 ≤ qty−issued_qty；取消出库须 ≤ issued_qty）。
 */
@Getter
@Setter
public class StockDocIssueRequest {

    @Valid
    @NotBlank
    @Size(min = 8, max = 128)
    private String idempotencyKey;

    @NotNull
    @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
    private List<Line> lines;

    /** Required by the cancellation endpoint; ignored for a forward issue. */
    @Size(max = 1000)
    private String reason;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID itemId;

        @NotNull
        @Positive
        private BigDecimal qty;
    }
}
