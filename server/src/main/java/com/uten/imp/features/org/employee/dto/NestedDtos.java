package com.uten.imp.features.org.employee.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.LocalDate;
import java.util.UUID;

/** 员工详情嵌套项 DTO（紧急联系人、任职轨迹）。 */
public final class NestedDtos {

    private NestedDtos() {}

    @Getter
    @AllArgsConstructor
    public static class EmergencyContactDto {
        private UUID id;
        private String name;
        private String phone;   // 明文(hr/admin) 或脱敏
        private String relationship;
    }

    @Getter
    @AllArgsConstructor
    public static class EmploymentHistoryDto {
        private UUID id;
        private String eventType;        // onboard/transfer/resign
        private UUID fromDeptId;
        private UUID toDeptId;
        private String fromDeptName;
        private String toDeptName;
        private LocalDate eventDate;
        private String remark;
    }

    @Getter
    @AllArgsConstructor
    public static class CredentialDto {
        private UUID id;
        private String type;
        private String name;
        private String certNo;
        private LocalDate issuedAt;
        private LocalDate expiresAt;
    }

    @Getter
    @AllArgsConstructor
    public static class EducationDto {
        private UUID id;
        private String degree;
        private String school;
        private String major;
        private LocalDate startDate;
        private LocalDate endDate;
    }
}
