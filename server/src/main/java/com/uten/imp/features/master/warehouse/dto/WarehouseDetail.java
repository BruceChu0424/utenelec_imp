package com.uten.imp.features.master.warehouse.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 仓库详情（扁平主档，与列表项同字段，保留独立 DTO 与基础资料范式对齐）。
 */
@Getter
@AllArgsConstructor
public class WarehouseDetail {
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
    /** 上级仓库(ADR-145 单主仓): 只有主仓为 null。 */
    private UUID parentId;
    /** 线边仓标记（V584 车间内部直送）：车间自己的料架，直送候选与投入都指向它。 */
    private boolean lineSide;
    /** 仓库用途(ADR-145): true=不良品仓, false=良品仓。 */
    private boolean defective;
    /** 新单能不能选它(ADR-145, 与字典同一定义 fn_warehouse_is_good_stock_leaf)。 */
    private boolean selectableForNew;
    /** 新选不良品子仓(ADR-146, fn_warehouse_is_defective_leaf)。 */
    private boolean selectableDefective;
}
