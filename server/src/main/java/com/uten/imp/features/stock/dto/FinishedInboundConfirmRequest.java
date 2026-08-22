package com.uten.imp.features.stock.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Warehouse physical acceptance for a production-generated FINISHED_IN draft. */
@Getter
@Setter
public class FinishedInboundConfirmRequest {

    @NotBlank
    @Size(min = 8, max = 128)
    private String idempotencyKey;

    /** Required when any accepted quantity is below the production report quantity. */
    @Size(max = 1_000)
    private String varianceReason;

    @Valid
    @NotNull
    @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
    private List<Line> lines;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID itemId;

        @NotNull
        @PositiveOrZero
        private BigDecimal acceptedQty;
    }
}
