package com.uten.imp.features.org.department.dto;

import java.util.List;
import java.util.UUID;

/**
 * 员工选择器专用的最小组织树节点。
 *
 * <p>只返回定位员工所需的部门标识、名称和层级；不携带负责人、编制等部门管理字段。
 * 接口权限与员工摘要列表一致（employee:view），不会借选择器扩大 employee:view 的数据范围。
 */
public record DepartmentPickerNode(
        UUID id,
        String code,
        String name,
        String level,
        UUID parentId,
        List<DepartmentPickerNode> children) {}
