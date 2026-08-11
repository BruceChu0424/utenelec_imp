package com.uten.imp.features.notice.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 发送/更新祝福请求体（一人一条，重复发送=编辑）。
 */
public record NoticeBlessingRequest(
        @NotBlank
        @Size(max = RequestLimits.NOTICE_BLESSING_LENGTH) String content) {
}
