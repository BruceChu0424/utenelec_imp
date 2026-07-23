package com.uten.imp.features.org.department.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

@Getter
@AllArgsConstructor
public class DepartmentDetail {
    private UUID id;
    private String code;
    private String name;
    private String level;
    private UUID parentId;
    private String parentName;
    private UUID managerId;
    private String managerName;
    private Integer sortOrder;
    private Integer headcount;
    private String path;
    private long childCount;
    private long employeeCount;
}
