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
    private UUID workshopDepartmentId;
    private String workshopDepartmentName;
    /** B_Storage.WorkID -> Sys_Operator.ID compatibility snapshot. */
    private Integer legacyOperatorId;
    /** @deprecated compatibility alias retained for older clients. */
    @Deprecated
    private Integer workshopLegacyId;
    private String status;
    private Integer legacyId;
    /** 上级仓库（V476 主/子层级）；null=独立顶层。 */
    private UUID parentId;
    /** 上级仓库名称（列表列展示用；独立顶层为 null）。 */
    private String parentName;
}
