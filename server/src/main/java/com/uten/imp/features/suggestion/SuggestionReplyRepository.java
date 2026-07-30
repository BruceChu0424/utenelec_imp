package com.uten.imp.features.suggestion;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface SuggestionReplyRepository extends JpaRepository<SuggestionReply, UUID> {

    List<SuggestionReply> findBySuggestionIdOrderByRepliedAtAsc(UUID suggestionId);
}
