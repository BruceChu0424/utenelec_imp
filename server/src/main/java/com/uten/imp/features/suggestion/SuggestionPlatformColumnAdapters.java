package com.uten.imp.features.suggestion;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.*;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;

@Configuration
@RequiredArgsConstructor
public class SuggestionPlatformColumnAdapters {
    private final SuggestionService suggestions;private final SecurityContextCurrentUser current;private final ObjectMapper json;
    @Bean public PlatformColumnResourceAdapter suggestionPlatformColumns() {
        return new ReadOnlyPlatformColumnAdapter("suggestion","建议反馈",current,json,Set.of("suggestion:submit"),Set.of(),suggestions::getById,
                List.of(new FactDefinition("likes","点赞数",false),new FactDefinition("replyCount","回复数",false)));
    }
}
