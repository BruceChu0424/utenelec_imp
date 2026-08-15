package com.uten.imp.features.master.warehouse.dto;

import java.util.UUID;

/** Minimal production-workshop option exposed under warehouse:view. */
public record WarehouseWorkshopOption(UUID id, String code, String name) {
}
