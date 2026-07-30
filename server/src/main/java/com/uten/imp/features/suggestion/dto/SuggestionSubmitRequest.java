package com.uten.imp.features.suggestion.dto;

/** 提交建议请求。category 缺省 other；isAnonymous 缺省 false。 */
public record SuggestionSubmitRequest(
        String category,
        String title,
        String content,
        Boolean isAnonymous) {
}
