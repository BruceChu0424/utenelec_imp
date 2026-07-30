package com.uten.imp.features.suggestion;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface SuggestionRepository extends JpaRepository<Suggestion, UUID> {

    List<Suggestion> findBySubmitterIdOrderBySubmittedAtDesc(UUID submitterId);

    List<Suggestion> findAllByOrderBySubmittedAtDesc();

    List<Suggestion> findByCategoryOrderBySubmittedAtDesc(String category);
}
