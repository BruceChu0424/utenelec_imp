package com.uten.imp.features.suggestion.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * 官方回复请求。newStatus 可选——回复时顺带推进状态
 * （reviewing/resolved/rejected），不传则状态不变。
 */
public record SuggestionReplyRequest(
        @NotBlank(message = "回复内容不能为空")
        @Size(max = 5_000, message = "回复内容最多 5000 字")
        String content,
        @Pattern(regexp = "^(reviewing|resolved|rejected)$", message = "建议状态不合法")
        String newStatus) {
}
