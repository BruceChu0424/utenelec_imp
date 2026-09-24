package com.uten.imp.features.master.warehouse.dto;

import java.util.UUID;

/** 仓库资料列表「负责人」列用的一条负责关系(ADR-115)。 */
public record WarehouseKeeperAssignment(UUID warehouseId, UUID employeeId, String name) {
}
