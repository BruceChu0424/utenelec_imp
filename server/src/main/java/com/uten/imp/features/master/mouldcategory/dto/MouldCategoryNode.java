package com.uten.imp.features.master.mouldcategory.dto;

import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 模具分类树节点；id/parentId 是 UUID 关系，code/codePrefix 只用于显示与编号规则。 */
@Getter
@Setter
@NoArgsConstructor
public class MouldCategoryNode {
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
    private List<MouldCategoryNode> children = new ArrayList<>();
}
