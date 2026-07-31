package com.uten.imp.features.notice.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** 自定义通知接收范围。部门按发布时的组织子树展开，人员与部门结果去重。 */
public record NoticeAudienceRequest(
        @Size(max = RequestLimits.NOTICE_AUDIENCE_TARGETS) List<UUID> departmentIds,
        @Size(max = RequestLimits.NOTICE_AUDIENCE_TARGETS) List<UUID> employeeIds) {
}
