package com.uten.imp.features.master.materialcategory.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class MaterialCategorySaveRequest {
    /** 可编辑备注；老库分类编码迁移到 remark/legacyCodeSnapshot，不再作为关联键。 */
    private String remark;

    /** 留空继承最近上级；显式填写后覆盖上级，供该子树主档自动编号；数据库校验全局终身占用。 */
    private String codePrefix;

    @NotBlank
    private String name;

    private UUID parentId;      // UUID 父关系；为空 = 顶级根

    private Integer sortOrder = 0;
}
