package com.uten.imp.features.ai.job;

import java.time.OffsetDateTime;
import java.util.Map;
import java.util.UUID;

/**
 * 任务快照(与 Flutter {@code AiJobSnapshot} 一一对应)。{@code result} 只在成功且尚未被单据采用、
 * 尚未清空时返回, 并已按当前读者的权限过滤; {@code jobId} 与 {@code id} 相同(兼容提交响应)。
 */
public record AiJobView(
        UUID id,
        UUID jobId,
        String kind,
        String status,
        String stage,
        int progress,
        boolean cancelRequested,
        Map<String, Object> result,
        String errorCode,
        String errorMessage,
        String inputName,
        OffsetDateTime createdAt,
        OffsetDateTime startedAt,
        OffsetDateTime finishedAt) {
}
