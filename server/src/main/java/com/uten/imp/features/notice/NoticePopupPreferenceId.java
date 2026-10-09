package com.uten.imp.features.notice;

import lombok.EqualsAndHashCode;

import java.io.Serializable;
import java.util.UUID;

/** {@link NoticePopupPreference} 复合主键：(user_id, source_event)。 */
@EqualsAndHashCode
public class NoticePopupPreferenceId implements Serializable {

    private UUID userId;
    private String sourceEvent;

    public NoticePopupPreferenceId() {
    }

    public NoticePopupPreferenceId(UUID userId, String sourceEvent) {
        this.userId = userId;
        this.sourceEvent = sourceEvent;
    }
}
