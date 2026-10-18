package com.uten.imp.features.org.department.dto;

import java.util.List;
import java.util.UUID;

/**
 * 员工选择器专用的最小组织树节点。
 *
 * <p>只返回定位员工所需的部门标识、名称和层级；不携带负责人、编制等部门管理字段。
 * 仅供已有内部人员选择能力的业务使用；候选人仍由各业务接口独立授权，
 * 不会借组织路径开放员工名册或部门管理资料，访客主体不可读取。
 */
public record DepartmentPickerNode(
        UUID id,
        String code,
        String name,
        String level,
        UUID parentId,
        List<DepartmentPickerNode> children) {}
