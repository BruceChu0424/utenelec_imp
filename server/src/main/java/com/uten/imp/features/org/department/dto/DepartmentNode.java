package com.uten.imp.features.org.department.dto;

import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 部门树节点（递归 children）。 */
@Getter
@Setter
@NoArgsConstructor
public class DepartmentNode {
    private UUID id;
    private String code;
    private String name;
    private String level;
    private UUID parentId;
    private UUID managerId;
    private String managerName;
    private Integer sortOrder;
    private Integer headcount;
    private List<DepartmentNode> children = new ArrayList<>();
}
