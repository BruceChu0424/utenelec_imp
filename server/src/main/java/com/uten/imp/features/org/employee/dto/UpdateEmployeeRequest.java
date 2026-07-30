package com.uten.imp.features.org.employee.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 员工编辑（部分更新）。非 null 字段才更新；敏感/薪资字段若提供则重新加密；
 *  certificates/educations 若提供（非 null，含空数组）则整体替换。 */
public record UpdateEmployeeRequest(
        String fullName,
        String gender,
        LocalDate birthDate,
        String ethnicity,
        String politicalStatus,
        String maritalStatus,
        String hujiAddress,
        String residenceAddress,
        UUID departmentId,
        UUID positionId,
        UUID supervisorId,
        String workLocation,
        String seatNo,
        String attendanceGroup,
        String officePhone,
        String email,
        String paperArchiveNo,
        String status,
        String employmentType,
        LocalDate confirmedAt,
        // 敏感（提供则重新加密）
        String idNumber,
        String phone,
        String bankAccount,
        String bankBranch,
        // 薪资（提供则重新加密）
        String baseSalary,
        String perfSalary,
        String socialInsuranceBase,
        String housingFundBase,
        String allowanceStandard,
        String socialInsuranceLocation,
        // 子集合（非 null 则整体替换；空数组 = 清空）
        @Valid
        @Size(max = RequestLimits.EMPLOYEE_NESTED_ITEMS)
        List<OnboardingRequest.CredentialInput> certificates,
        @Valid
        @Size(max = RequestLimits.EMPLOYEE_NESTED_ITEMS)
        List<OnboardingRequest.EducationInput> educations
) {}
