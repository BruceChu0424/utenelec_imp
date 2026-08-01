package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

/** Explicit warehouse pick/exception/handover transition. */
@Getter
@Setter
public class WarehouseWorkTransitionRequest {

    @NotBlank
    @Size(max = 32)
    private String targetStatus;

    @Size(max = 500)
    private String reason;
}
