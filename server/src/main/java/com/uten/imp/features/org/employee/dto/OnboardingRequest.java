package com.uten.imp.features.org.employee.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 入职 payload（对应前端 5 步向导）。一个原子事务内创建
 * employee + sensitive + compensation + contract + history + user(一次性临时密码) + userRoles。
 */
public record OnboardingRequest(
        @Valid Profile profile,
        @Valid Employment employment,
        @Valid Compensation compensation,
        @Valid Contract contract,
        @Valid
        @Size(max = RequestLimits.EMPLOYEE_NESTED_ITEMS)
        List<@Valid EmergencyContactInput> emergencyContacts,
        @Valid
        @Size(max = RequestLimits.EMPLOYEE_NESTED_ITEMS)
        List<@Valid CredentialInput> certificates,
        @Valid
        @Size(max = RequestLimits.EMPLOYEE_NESTED_ITEMS)
        List<@Valid EducationInput> educations,
        @Valid Account account
) {
    public record Profile(
            // 旧客户端兼容字段；服务端始终自行生成工号并忽略该值。
            String code, String fullName, String gender, String idType, String idNumber,
            LocalDate birthDate, String phone, String email,
            String ethnicity, String politicalStatus, String maritalStatus,
            String hujiAddress, String residenceAddress
    ) {}

    public record Employment(
            UUID departmentId, UUID positionId, UUID supervisorId,
            String positionName,
            LocalDate hireDate, String employmentType, String status,
            String workLocation, String seatNo, String attendanceGroup, String officePhone, String paperArchiveNo
    ) {}

    public record Compensation(
            String baseSalary, String perfSalary, String bankAccount, String bankBranch,
            String socialInsuranceBase, String socialInsuranceLocation,
            String housingFundBase, String allowanceStandard
    ) {}

    public record Contract(
            String contractType, LocalDate startDate, LocalDate endDate, Integer probationMonths
    ) {}

    public record EmergencyContactInput(
            String name, String phone, String relationship, Integer sortOrder
    ) {}

    public record CredentialInput(
            String type, String name, String certNo, LocalDate issuedAt, LocalDate expiresAt
    ) {}

    public record EducationInput(
            String degree, String school, String major, LocalDate startDate, LocalDate endDate
    ) {}

    /** roles 默认 [employee]；loginAccount 默认 = 手机号。 */
    public record Account(
            @Size(max = RequestLimits.EMPLOYEE_NESTED_ITEMS) List<String> roles,
            String loginAccount
    ) {}
}
