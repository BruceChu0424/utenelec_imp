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
 * <p>逐字段照抄 colors 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Color 迁移：legacy_id=B_Color.ID（溯源+重跑幂等），code=Number、name=ColorName、status=Status。
 * B_Color 实测为扁平表（ParentID 全 0），无分类树。
 *
 * <p>新业务通过 goods.color_id UUID 关联；color_legacy_id 仅为旧库兼容影子。
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

    private String code;        // Number；历史重复原样保留，新写入由 V279 全局终身预约
    private String name;        // ColorName 颜色名称
    private String status;      // Status（使用/禁用）
}
