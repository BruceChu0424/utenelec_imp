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

/**
 * Warehouse physical acceptance for a production-generated FINISHED_IN draft.
 *
 * <p>ADR-148: the warehouse counts each physical handoff lot once; the server distributes the
 * accepted quantity to the lot's slices (demand first, then planned public, then actual surplus)
 * and the shortfall stays in the residual draft starting from the actual-surplus slice.</p>
 */
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
    private List<Lot> lots;

    @Getter
    @Setter
    public static class Lot {
        @NotNull
        private UUID lotId;

        @NotNull
        @PositiveOrZero
        private BigDecimal acceptedQty;
    }
}
