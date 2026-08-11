package com.uten.imp.features.notice.dto;

/** 通知发布页人员选择器候选；只暴露组织目录所需的非敏感字段。 */
public record NoticeAudienceEmployeeDto(
        String id,
        String name,
        String code,
        String departmentName) {
}
