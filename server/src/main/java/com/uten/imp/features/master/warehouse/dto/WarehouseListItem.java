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
    /** 上级仓库(ADR-145 单主仓): 只有主仓为 null, 其余仓都是主仓的直属子仓。 */
    private UUID parentId;
    /** 上级仓库名称(列表列展示用; 主仓为 null)。 */
    private String parentName;
    /** 线边仓标记（V584 车间内部直送）。 */
    private boolean lineSide;
    /** 仓库用途(ADR-145): true=不良品仓, false=良品仓。 */
    private boolean defective;
    /**
     * 新单能不能选它(ADR-145, 服务端只算一次): 启用、记账、作业叶仓、祖先全部启用、
     * 不是车间内料仓、不是不良品仓(SQL fn_warehouse_is_good_stock_leaf)。前端不再自己推算。
     */
    private boolean selectableForNew;
    /**
     * 专门通道/盘点/处置出库能不能选它(ADR-146, 服务端只算一次): 启用、记账、作业叶仓、
     * 祖先全部启用、是不良品仓(SQL fn_warehouse_is_defective_leaf)。
     */
    private boolean selectableDefective;
}
