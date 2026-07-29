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
 * 员工详情。基础字段对所有授权角色可见；敏感字段（身份证/手机/银行/薪资）由 service 按角色脱敏或省略。
 */
@Getter
@Setter
public class EmployeeDetail {

    // 基本信息（全员可见）
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

    // 敏感 PII（按角色脱敏/省略）
    private String idNumber;        // 明文(hr/admin) 或 ****1234(其他) 或 null
    private String phone;           // 明文(hr/admin) 或 138****1234(其他)
    private String bankAccount;     // 明文(hr/admin) 或 null
    private String bankBranch;      // 明文(hr/admin) 或 null

    // 薪资（仅 hr/finance/admin 可见，否则为 null）
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
