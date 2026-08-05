package com.uten.imp.features.org.employee.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.LocalDate;
import java.util.UUID;

/** 员工列表项（摘要，不含任何敏感 PII）。 */
@Getter
@AllArgsConstructor
public class EmployeeListItem {
    private UUID id;
    private String code;
    private String fullName;
    private String gender;
    private String departmentName;
    private String positionName;
    private String status;
    private String employmentType;
    private LocalDate hireDate;
    private String positionLevel;
    private boolean departmentManager;
    private int leaderRank;
    private UUID departmentId;   // 所属部门 id（部门管理页"搜员工定位部门"用）
    private String matchedPlates; // 搜索命中车牌时返回（「、」分隔），否则 null —— ADR-021 按车牌找人
}
