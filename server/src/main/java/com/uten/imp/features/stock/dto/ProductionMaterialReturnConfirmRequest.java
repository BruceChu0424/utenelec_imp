package com.uten.imp.features.stock.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import java.util.UUID;

/** Warehouse staff select where the current workshop's surplus is physically received. */
public record ProductionMaterialReturnConfirmRequest(
        @NotNull UUID warehouseId,
        @NotNull @Pattern(regexp="[A-Za-z0-9._:-]{8,128}") String idempotencyKey) {}
