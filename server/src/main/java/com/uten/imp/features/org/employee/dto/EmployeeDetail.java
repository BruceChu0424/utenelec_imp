package com.uten.imp.features.org.employee.dto;

import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

// NestedDtos 内嵌类（同包，需显式导入）
import com.uten.imp.features.org.employee.dto.NestedDtos.CredentialDto;
import com.uten.imp.features.org.employee.dto.NestedDtos.EducationDto;
import com.uten.imp.features.org.employee.dto.NestedDtos.EmergencyContactDto;
import com.uten.imp.features.org.employee.dto.NestedDtos.EmploymentHistoryDto;

/**
 * 员工详情。基础任职字段对持档案查看权限者可见；PII 与薪酬字段由 service 按
 * {@code employee:pii:view}/{@code employee:compensation:view} 分别脱敏或省略。
 */
@Getter
@Setter
public class EmployeeDetail {

    // 基本信息（人口属性、地址和出生日期仍受 employee:pii:view 保护）
    private UUID id;
    private String code;
    private String fullName;
    private String gender;
    private String idType;
    private LocalDate birthDate;
    private String ethnicity;
    private String politicalStatus;
    private String maritalStatus;
    private String hujiAddress;
    private String residenceAddress;

    // 组织与用工
    private UUID departmentId;
    private String departmentName;
    private UUID positionId;
    private String positionName;
    private String positionLevel;
    private boolean departmentManager;
    private int leaderRank;
    private UUID supervisorId;
    private String supervisorName;
    private LocalDate hireDate;
    private LocalDate confirmedAt;
    private String status;
    private String employmentType;
    private String workLocation;
    private String seatNo;
    private String attendanceGroup;
    private String officePhone;
    private String email;
    private String paperArchiveNo;

    // 敏感 PII（employee:pii:view 决定明文；否则脱敏或省略）
    private String idNumber;        // 有权限时明文，否则 ****1234 或 null
    private String phone;           // 有权限时明文，否则 138****1234
    private String bankAccount;     // 有权限时明文，否则 null
    private String bankBranch;      // 有权限时明文，否则 null

    // 薪资（仅 employee:compensation:view 可见，否则为 null）
    private String baseSalary;
    private String perfSalary;
    private String socialInsuranceBase;
    private String socialInsuranceLocation;
    private String housingFundBase;
    private String allowanceStandard;

    // 合同
    private String contractType;
    private LocalDate contractStart;
    private LocalDate contractEnd;
    private Integer probationMonths;
    private LocalDate probationEndDate;
    private int renewCount;

    // 登录账号状态（active/locked/disabled；null = 未开通账号）
    private String accountStatus;

    // 嵌套
    private List<EmergencyContactDto> emergencyContacts;
    private List<EmploymentHistoryDto> history;
    private List<CredentialDto> certificates;
    private List<EducationDto> educations;
}
