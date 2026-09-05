package com.uten.imp.features.master.warehouse;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/**
 * 仓库主档（基础资料-仓库资料）。
 *
 * <p>逐字段对应 warehouses 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Storage 迁移：legacy_id=B_Storage.ID（溯源+重跑幂等），code=Number、name=Storage_Name、
 * location=Location、remark=Remark、accountable=IsCal、legacyOperatorId=WorkID、status=Status。
 * B_Storage 扁平表（ParentID 全 0），无分类树。
 *
 * <p>采购收货/退货单据 warehouse_id 引用本表；库存 stock_movements/balances 按仓库维度记账。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "warehouses")
public class Warehouse extends SoftDeletableEntity {

    /** 老库 B_Storage.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    private String code;        // Number 编号（C01/C04...）
    private String name;        // Storage_Name 仓库名称
    private String location;    // Location 仓库位置
    private String remark;      // Remark

    /** 是否参与库存核算（源 IsCal，⚠ 取反：老库 IsCal=0=参与核算）。 */
    @Column(name = "is_accountable", nullable = false)
    private boolean accountable = true;

    /** 不良品仓标记（老库无字段，按名称「不良」识别）。即时库存「全部」默认含、开关可剔除。 */
    @Column(name = "is_defective", nullable = false)
    private boolean defective = false;

    /** 所属车间 legacy id（源 WorkID，暂不建 FK）。 */
    @Column(name = "workshop_legacy_id")
    private Integer workshopLegacyId;

    /** Canonical B_Storage.WorkID -> Sys_Operator.ID compatibility snapshot. */
    @Column(name = "legacy_operator_id")
    private Integer legacyOperatorId;

    /**
     * Live workshop identity. The database guard restricts this relationship
     * to a non-deleted direct child of the DEPT_PROD organization node.
     */
    @Column(name = "workshop_department_id")
    private UUID workshopDepartmentId;

    /**
     * 上级仓库（V476 主/子层级）：null=独立顶层。父仓仅作查询聚合与下拉分组，
     * 单据/收发存仍落到具体仓库；保存时服务端校验防环（见 WarehouseService）。
     */
    @Column(name = "parent_id")
    private UUID parentId;

    private String status;      // Status（使用/禁用）

    /** 单据迁移/运行时自动补录标记。 */
    @Column(name = "auto_created", nullable = false)
    private boolean autoCreated = false;
}
