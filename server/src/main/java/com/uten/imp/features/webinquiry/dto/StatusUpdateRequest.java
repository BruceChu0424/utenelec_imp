package com.uten.imp.features.webinquiry.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/** 跟进状态推进（new/following/closed；converted 只能走 convert 接口）。 */
public record StatusUpdateRequest(
        @NotBlank @Pattern(regexp = "new|following|closed") String status,
        @Size(max = 500) String note,
        Boolean assignToMe
) {
}
