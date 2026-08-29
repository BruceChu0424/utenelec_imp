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
        private String phone;   // 本人或 employee:pii:view 可见明文，否则脱敏
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

    /** 员工车辆（ADR-021；车牌明文，employee:view 可见，用于「按车牌找人」）。 */
    @Getter
    @AllArgsConstructor
    public static class VehicleDto {
        private UUID id;
        private String plateNo;
        private String vehicleType;
        private String brandModel;
        private String color;
        private String remark;
    }

    /** 备用手机号（本人或 employee:pii:view 明文，否则掩码）。 */
    @Getter
    @AllArgsConstructor
    public static class PhoneDto {
        private UUID id;
        private String label;
        private String phone;
    }

    /**
     * 劳动合同（时间线一项）。daysToExpiry 为 null 表示无固定期限/已过期无意义；
     * expiring=true 表示 30 天内到期（预警）；ended=true 表示已到期。
     */
    @Getter
    @AllArgsConstructor
    public static class ContractDto {
        private UUID id;
        private String contractType;
        private LocalDate startDate;
        private LocalDate endDate;        // null = 无固定期限
        private Integer probationMonths;
        private Integer signOrder;
        private Integer daysToExpiry;     // 距到期天数；null=无固定期限
        private boolean expiring;         // 30 天内到期
        private boolean ended;            // 已到期
    }

    /** 车辆写入项（整体替换语义；车牌必填，其余非必填）。 */
    public record VehicleInput(
            String plateNo, String vehicleType, String brandModel,
            String color, String remark, Integer sortOrder) {}

    /** 备用手机号写入项（整体替换语义；号码必填，标签默认「备用」）。 */
    public record PhoneInput(String label, String phone, Integer sortOrder) {}
}
