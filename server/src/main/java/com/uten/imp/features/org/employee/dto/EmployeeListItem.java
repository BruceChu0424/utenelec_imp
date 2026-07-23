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
}
