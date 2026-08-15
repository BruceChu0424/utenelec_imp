package com.uten.imp.features.master.materialcategory.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class MaterialCategoryUpdateRequest {
    @NotBlank
    private String name;

    private UUID parentId;      // UUID 父关系；改上级会做防成环校验 + 子树深度重算

    private Integer sortOrder;

    /** null 表示旧客户端未提交；空字符串表示清除并继承上级；非空前缀由数据库全局终身预约。 */
    private String codePrefix;

    /** null 表示旧客户端未提交；空字符串表示清空备注；不改写不可变的老库编码快照。 */
    private String remark;

    private Long version;
}
