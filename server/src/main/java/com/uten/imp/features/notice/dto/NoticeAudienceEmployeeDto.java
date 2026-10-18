package com.uten.imp.features.notice.dto;

/** 通知发布页人员选择器候选；只暴露组织目录所需的非敏感字段。 */
public record NoticeAudienceEmployeeDto(
        String id,
        String name,
        String code,
        String departmentId,
        String departmentName,
        String accountStatus,
        String employmentStatus) {
    public NoticeAudienceEmployeeDto(String id, String name, String code,
                                     String departmentId, String departmentName) {
        this(id, name, code, departmentId, departmentName, null, null);
    }
}
