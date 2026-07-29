package com.uten.imp.features.suggestion;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface SuggestionLikeRepository extends JpaRepository<SuggestionLike, SuggestionLikeId> {

    long countByIdSuggestionId(UUID suggestionId);

    List<SuggestionLike> findByIdUserId(UUID userId);
}
