package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import java.util.List;
import java.util.UUID;

/** Explicit warehouse pick/exception/handover transition. */
@Getter
@Setter
public class WarehouseWorkTransitionRequest {

    @NotBlank
    @Size(max = 32)
    private String targetStatus;

    @Size(max = 500)
    private String reason;

    /** Explicit physical warehouse choice, accepted only when beginning picking. */
    private UUID warehouseId;

    @Valid
    @Size(max = 500)
    private List<StockPlace> stockPlaces;

    public record StockPlace(@NotNull UUID shipmentItemId, @Size(max = 200) String stockPlace) {}
}
