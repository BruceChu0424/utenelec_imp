package com.uten.imp.features.notice.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** 批量删除请求（从当前用户列表移除）。 */
public record NoticeBatchDeleteRequest(
        @NotNull @Size(max = RequestLimits.BATCH_IDS) List<UUID> ids) {
}
