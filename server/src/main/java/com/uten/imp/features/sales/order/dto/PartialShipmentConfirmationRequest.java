package com.uten.imp.features.sales.order.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

/** Records or revokes the customer's approval for partial shipment. */
@Getter
@Setter
public class PartialShipmentConfirmationRequest {

    @NotNull
    private Boolean confirmed;

    @NotBlank
    @Size(max = 500)
    private String reason;
}
