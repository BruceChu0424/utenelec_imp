package com.uten.imp.features.suggestion.dto;

/**
 * 官方回复请求。newStatus 可选——回复时顺带推进状态
 * （reviewing/resolved/rejected），不传则状态不变。
 */
public record SuggestionReplyRequest(
        String content,
        String newStatus) {
}
