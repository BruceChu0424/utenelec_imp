package com.uten.imp.features.master.unit;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/**
 * 基本单位主档（基础资料-基本单位）。
 *
 * <p>逐字段照抄 V40 units 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Unit 迁移：legacy_id=B_Unit.ID（溯源+重跑幂等），code=Number、name=Unit_Name、status=Status。
 * B_Unit 实测为扁平表（ParentID 全 0），无分类树。
 *
 * <p>货品 goods.unit_legacy_id 指向本表 legacy_id（货品单位名称解析据此关联，见 GoodsService）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "units")
public class Unit extends SoftDeletableEntity {

    /** 老库 B_Unit.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    private String code;        // Number 编号
    private String name;        // Unit_Name 单位名称（如 个/套/只/kg）
    private String status;      // Status（使用/禁用）
}
