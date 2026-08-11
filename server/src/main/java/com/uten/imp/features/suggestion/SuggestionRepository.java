package com.uten.imp.features.suggestion;

import jakarta.persistence.LockModeType;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface SuggestionRepository extends JpaRepository<Suggestion, UUID> {

    Page<Suggestion> findBySubmitterId(UUID submitterId, Pageable pageable);

    Page<Suggestion> findByCategory(String category, Pageable pageable);

    Page<Suggestion> findBySubmitterIdAndCategory(
            UUID submitterId,
            String category,
            Pageable pageable);

    /**
     * Serializes mutations of one suggestion.
     *
     * <p>Likes use the suggestion row as their transaction mutex. This closes the
     * exists-then-insert/delete race without relying on process-local locks and also
     * serializes status transitions made by concurrent official replies.
     */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select s from Suggestion s where s.id = :id")
    Optional<Suggestion> findByIdForUpdate(@Param("id") UUID id);
}
