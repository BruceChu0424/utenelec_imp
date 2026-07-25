package com.uten.imp.features.master.color;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/**
 * 颜色主档（基础资料-颜色资料）。
 *
 * <p>逐字段照抄 V39 colors 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Color 迁移：legacy_id=B_Color.ID（溯源+重跑幂等），code=Number、name=ColorName、status=Status。
 * B_Color 实测为扁平表（ParentID 全 0），无分类树。
 *
 * <p>货品 goods.color_legacy_id 指向本表 legacy_id（货品颜色名称解析据此关联，见 GoodsService）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "colors")
public class Color extends SoftDeletableEntity {

    /** 老库 B_Color.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    private String code;        // Number 编号（老库重复多，不唯一）
    private String name;        // ColorName 颜色名称
    private String status;      // Status（使用/禁用）
}
