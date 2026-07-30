package com.uten.imp.features.suggestion;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface SuggestionReplyRepository extends JpaRepository<SuggestionReply, UUID> {

    List<SuggestionReply> findBySuggestionIdOrderByRepliedAtAsc(UUID suggestionId);

    long countBySuggestionId(UUID suggestionId);

    @Query("""
            select r.suggestionId as suggestionId, count(r) as total
            from SuggestionReply r
            where r.suggestionId in :suggestionIds
            group by r.suggestionId
            """)
    List<SuggestionCount> countBySuggestionIds(
            @Param("suggestionIds") List<UUID> suggestionIds);

    interface SuggestionCount {
        UUID getSuggestionId();

        long getTotal();
    }
}
