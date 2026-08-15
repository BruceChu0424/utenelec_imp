package com.uten.imp.features.master.mouldcategory.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class MouldCategorySaveRequest {
    /** 可编辑备注；老库分类编码迁移到备注/不可变快照，不再作为关联键。 */
    private String remark;
    /** 留空继承最近上级；显式前缀由数据库校验全局、终身占用。 */
    private String codePrefix;

    @NotBlank
    private String name;

    private UUID parentId;      // UUID 父关系；为空 = 顶级根

    private Integer sortOrder = 0;
}
