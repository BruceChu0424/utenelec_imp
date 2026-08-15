package com.uten.imp.features.master.mouldcategory;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/**
 * 模具分类树（基础资料-模具资料）。
 * 与 {@link com.uten.imp.features.master.materialcategory.MaterialCategory} 同构、独立成表。
 * 邻接表 parent + 真实深度 level + 物化路径 path（path 由 DB 触发器 trg_mouldcat_path 维护）。
 * 分类身份与父子关系只使用 UUID id；legacyId 仅用于迁移溯源。
 * 老库重复 code 原样保存在 remark/legacyCodeSnapshot，当前 code 是系统生成并由 V279
 * 全局终身预约的只读显示编号；codePrefix 只控制该子树模具的显示编号前缀。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "mould_categories")
public class MouldCategory extends SoftDeletableEntity {

    @Version
    private long version;

    /** 老库 SystemItem.ItemID（ItemclassID=18），迁移溯源 + 重跑/增量幂等；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(nullable = false)
    private String code;

    private String remark;

    @Column(name = "legacy_code_snapshot", updatable = false)
    private String legacyCodeSnapshot;

    @Column(name = "code_prefix")
    private String codePrefix;

    @Column(nullable = false)
    private String name;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "parent_id")
    private MouldCategory parent;

    /** 真实深度（根=0）。 */
    @Column(nullable = false)
    private Integer level = 0;

    @Column(name = "sort_order")
    private Integer sortOrder = 0;

    @Column(nullable = false)
    private String path = "/";
}
