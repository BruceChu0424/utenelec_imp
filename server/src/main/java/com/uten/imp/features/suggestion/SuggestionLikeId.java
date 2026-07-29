package com.uten.imp.features.suggestion;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;
import lombok.AllArgsConstructor;
import lombok.EqualsAndHashCode;
import lombok.Getter;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.util.UUID;

/** suggestion_likes 复合主键（suggestion_id + user_id）。 */
@Getter
@NoArgsConstructor
@AllArgsConstructor
@EqualsAndHashCode
@Embeddable
public class SuggestionLikeId implements Serializable {

    @Column(name = "suggestion_id", nullable = false)
    private UUID suggestionId;

    @Column(name = "user_id", nullable = false)
    private UUID userId;
}
