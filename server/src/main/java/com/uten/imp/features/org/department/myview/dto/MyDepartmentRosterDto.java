package com.uten.imp.features.org.department.myview.dto;

import java.util.List;
import java.util.UUID;

/**
 * "我的部门"员工卡片用的安全字段名单（问题 #20）——刻意不返回身份证/薪资/住址等敏感字段，
 * 也不复用需要 employee:view 权限的员工档案接口（普通员工没有这个权限点，看不到自己部门）。
 */
public record MyDepartmentRosterDto(
        UUID departmentId, String departmentName, List<Row> staff) {

    public record Row(
            UUID employeeId,
            String code,
            String fullName,
            String positionName,
            String officePhone,
            String email,
            boolean departmentManager,
            boolean isSelf) {}
}
