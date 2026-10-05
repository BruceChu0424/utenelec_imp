package com.uten.imp.features.master.warehouse.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** 整组替换某仓库的负责人(ADR-115/ADR-149); 空列表 = 清空(该仓的任务与通知回到主管, 其他人也能看到)。 */
public record WarehouseKeeperSaveRequest(
        @NotNull @Size(max = WarehouseKeeperSaveRequest.MAX_KEEPERS) List<@NotNull UUID> employeeIds) {

    public static final int MAX_KEEPERS = 20;
}
