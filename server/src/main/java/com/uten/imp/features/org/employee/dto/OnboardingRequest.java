package com.uten.imp.features.org.employee.dto;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 入职 payload（对应前端 5 步向导）。一个原子事务内创建
 * employee + sensitive + compensation + contract + history + user(账号,密码由身份证后六位派生) + userRoles。
 */
public record OnboardingRequest(
        Profile profile,
        Employment employment,
        Compensation compensation,
        Contract contract,
        List<EmergencyContactInput> emergencyContacts,
        Account account
) {
    public record Profile(
            String code, String fullName, String gender, String idType, String idNumber,
            LocalDate birthDate, String phone, String email,
            String ethnicity, String politicalStatus, String maritalStatus,
            String hujiAddress, String residenceAddress
    ) {}

    public record Employment(
            UUID departmentId, UUID positionId, UUID supervisorId,
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

    /** roles 默认 [employee]；loginAccount 默认 = 工号（不填则用 profile.code）。 */
    public record Account(
            List<String> roles, String loginAccount
    ) {}
}
