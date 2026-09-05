package com.uten.imp.features.master.materialcategory.dto;

import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 物料分类树节点；id/parentId 是 UUID 关系，code/codePrefix 只用于显示与编号规则。 */
@Getter
@Setter
@NoArgsConstructor
public class MaterialCategoryNode {
    private UUID id;
    private String code;
    private String remark;
    private String codePrefix;
    private String name;
    private Integer level;
    private UUID parentId;
    private Integer sortOrder;
    private Integer legacyId;
    private boolean systemManaged;
    /** 子树（含自身）未软删货品数；仅 tree?withGoodsCounts=true 时返回，其余调用为 null。 */
    private Long goodsCount;
    private List<MaterialCategoryNode> children = new ArrayList<>();
}
