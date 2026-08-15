package com.uten.imp.features.attachment.dto;

import java.time.Instant;
import java.util.Map;

/**
 * 附件上传签发结果。confirmToken 把上传人、业务对象、storageKey、大小和类型绑定在一起，
 * 防止拿别人的 storageKey 重绑或覆盖。
 */
public record AttachmentPresignResponse(
        String storageKey,
        String url,
        String method,
        Map<String, String> headers,
        Map<String, String> formFields,
        Instant expiresAt,
        String confirmToken) {
}
