package com.uten.imp.features.master.warehouse.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** 整组替换某仓库的负责人(ADR-115); 空列表 = 清空(该仓的通知回到整个仓库部门)。 */
public record WarehouseKeeperSaveRequest(
        @NotNull @Size(max = WarehouseKeeperSaveRequest.MAX_KEEPERS) List<@NotNull UUID> employeeIds) {

    public static final int MAX_KEEPERS = 20;
}
