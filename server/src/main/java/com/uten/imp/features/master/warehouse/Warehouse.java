package com.uten.imp.features.master.warehouse;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/**
 * 仓库主档（基础资料-仓库资料）。
 *
 * <p>逐字段对应 V43 warehouses 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Storage 迁移：legacy_id=B_Storage.ID（溯源+重跑幂等），code=Number、name=Storage_Name、
 * location=Location、remark=Remark、accountable=IsCal、workshopLegacyId=WorkID、status=Status。
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

    /** 是否参与库存核算（源 IsCal）。 */
    @Column(name = "is_accountable", nullable = false)
    private boolean accountable = true;

    /** 所属车间 legacy id（源 WorkID，暂不建 FK）。 */
    @Column(name = "workshop_legacy_id")
    private Integer workshopLegacyId;

    private String status;      // Status（使用/禁用）

    /** 单据迁移/运行时自动补录标记。 */
    @Column(name = "auto_created", nullable = false)
    private boolean autoCreated = false;
}
