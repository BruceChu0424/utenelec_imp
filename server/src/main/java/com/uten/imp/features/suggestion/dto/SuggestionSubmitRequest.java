package com.uten.imp.features.suggestion.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/** 提交建议请求。category 缺省 other；isAnonymous 缺省 false。 */
public record SuggestionSubmitRequest(
        @Pattern(regexp = "^(product|process|welfare|environment|equipment|other)$",
                message = "建议类别不合法")
        String category,
        @NotBlank(message = "标题不能为空")
        @Size(max = 200, message = "标题最多 200 字")
        String title,
        @NotBlank(message = "内容不能为空")
        @Size(min = 10, max = 10_000, message = "内容长度须为 10–10000 字")
        String content,
        Boolean isAnonymous) {
}
