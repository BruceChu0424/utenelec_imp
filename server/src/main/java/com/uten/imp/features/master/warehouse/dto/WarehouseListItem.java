package com.uten.imp.features.master.warehouse.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 仓库列表项。
 */
@Getter
@AllArgsConstructor
public class WarehouseListItem {
    private UUID id;
    private String code;
    private String name;
    private String location;
    private String remark;
    private boolean accountable;
    private Integer workshopLegacyId;
    private String status;
    private Integer legacyId;
}
