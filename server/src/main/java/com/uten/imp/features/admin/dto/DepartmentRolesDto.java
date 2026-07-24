package com.uten.imp.features.admin.dto;

import java.util.List;
import java.util.UUID;

/** 部门默认角色（管理端列表项；未分配的部门 roles 为空数组）。 */
public record DepartmentRolesDto(UUID departmentId, String departmentName, List<String> roles) {}
