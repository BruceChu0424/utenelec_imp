package com.uten.imp.features.master.goods.dto;

import jakarta.validation.constraints.NotNull;

import java.util.UUID;

public record BomBatchMaintenanceCommit(@NotNull UUID previewToken, @NotNull Boolean confirmSharedChanges) { }
