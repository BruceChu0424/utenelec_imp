package com.uten.imp.features.notice.dto;

import java.time.Instant;

/**
 * 通知回执人列表项（仅展示姓名 + 回执时间，不暴露 user_id）。
 */
public record NoticeAcknowledgerDto(
        String name,
        Instant ackedAt) {
}
