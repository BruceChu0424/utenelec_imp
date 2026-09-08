package com.uten.imp.features.stock.allocation.dto;

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

/** Explicit shop-floor material usage/loss/WIP posting or reversal. */
@Getter
@Setter
public class ProductionMaterialSettlementRequest {

    /** Optional exact task context. Every submitted demand must belong to this segment. */
    private UUID executionSegmentId;

    @NotBlank
    @Size(min = 8, max = 128)
    private String idempotencyKey;

    @Size(max = 500)
    private String reason;

    @Valid
    @NotNull
    @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
    private List<Line> lines;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID demandId;

        @NotBlank
        private String settlementType;

        @NotNull
        @Positive
        private BigDecimal qtyBase;

        /** Required only by the reversal endpoint. */
        private UUID sourcePostingId;
    }
}
