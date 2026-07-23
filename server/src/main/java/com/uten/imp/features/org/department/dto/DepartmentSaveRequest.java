package com.uten.imp.features.org.department.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class DepartmentSaveRequest {
    @NotBlank
    private String code;

    @NotBlank
    private String name;

    @NotBlank
    private String level;   // 公司/决策层/管理中心/一级部门/二级班组/三级科室

    private UUID parentId;

    private UUID managerId;

    private Integer sortOrder = 0;
}
