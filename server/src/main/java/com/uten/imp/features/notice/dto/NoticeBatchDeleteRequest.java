package com.uten.imp.features.notice.dto;

import java.util.List;
import java.util.UUID;

/** 批量删除请求（从当前用户列表移除）。 */
public record NoticeBatchDeleteRequest(List<UUID> ids) {
}
