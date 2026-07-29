package com.uten.imp.features.notice.dto;

import java.util.List;

/**
 * 发布通知请求。type 默认 announcement；priority 默认 normal。
 * attachments 可选（文件名数组，当前仅展示用）。
 */
public record NoticePublishRequest(
        String title,
        String content,
        String type,
        Boolean topPriority,
        String priority,
        List<String> attachments) {
}
