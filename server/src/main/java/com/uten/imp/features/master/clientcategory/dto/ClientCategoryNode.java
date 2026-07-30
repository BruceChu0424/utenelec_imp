package com.uten.imp.features.master.clientcategory.dto;

import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 客户分类树节点（递归 children）。 */
@Getter
@Setter
@NoArgsConstructor
public class ClientCategoryNode {
    private UUID id;
    private String code;
    private String name;
    private Integer level;
    private UUID parentId;
    private Integer sortOrder;
    private Integer legacyId;
    private List<ClientCategoryNode> children = new ArrayList<>();
}
