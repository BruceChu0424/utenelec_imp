package com.uten.imp.features.suggestion.dto;

import java.time.Instant;
import java.util.List;

/**
 * 建议出参（列表/详情/提交回执共用）。
 * submitterName 已被服务端按匿名规则脱敏；likes/likedByMe 是当前用户维度。
 */
public record SuggestionDto(
        String id,
        String submitterId,
        String submitterName,
        String category,
        String title,
        String content,
        String status,
        Instant submittedAt,
        boolean isAnonymous,
        long likes,
        boolean likedByMe,
        List<SuggestionReplyDto> replies) {
}
