package com.uten.imp.features.suggestion;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface SuggestionLikeRepository extends JpaRepository<SuggestionLike, SuggestionLikeId> {

    long countByIdSuggestionId(UUID suggestionId);

    @Query("""
            select l.id.suggestionId
            from SuggestionLike l
            where l.id.userId = :userId
              and l.id.suggestionId in :suggestionIds
            """)
    List<UUID> findLikedSuggestionIds(
            @Param("userId") UUID userId,
            @Param("suggestionIds") List<UUID> suggestionIds);

    @Query("""
            select l.id.suggestionId as suggestionId, count(l) as total
            from SuggestionLike l
            where l.id.suggestionId in :suggestionIds
            group by l.id.suggestionId
            """)
    List<SuggestionCount> countBySuggestionIds(
            @Param("suggestionIds") List<UUID> suggestionIds);

    interface SuggestionCount {
        UUID getSuggestionId();

        long getTotal();
    }
}
