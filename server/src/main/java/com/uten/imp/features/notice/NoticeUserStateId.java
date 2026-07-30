package com.uten.imp.features.notice;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;
import lombok.AllArgsConstructor;
import lombok.EqualsAndHashCode;
import lombok.Getter;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.util.UUID;

/** notice_user_states 复合主键（notice_id + user_id）。 */
@Getter
@NoArgsConstructor
@AllArgsConstructor
@EqualsAndHashCode
@Embeddable
public class NoticeUserStateId implements Serializable {

    @Column(name = "notice_id", nullable = false)
    private UUID noticeId;

    @Column(name = "user_id", nullable = false)
    private UUID userId;
}
