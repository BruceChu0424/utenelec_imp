package com.uten.imp.features.suggestion;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;

/** 建议点赞（每用户一票，再点取消）。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "suggestion_likes")
public class SuggestionLike {

    @EmbeddedId
    private SuggestionLikeId id;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt = Instant.now();
}
