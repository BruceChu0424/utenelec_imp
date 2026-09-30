package com.uten.imp.features.profilechange;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.*;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;
import java.util.Map;

@Configuration
@RequiredArgsConstructor
public class ProfileChangePlatformColumnAdapters {
    private final ProfileChangeQueryService changes;private final SecurityContextCurrentUser current;private final ObjectMapper json;
    @Bean public PlatformColumnResourceAdapter profileChangePlatformColumns() {
        return new ReadOnlyPlatformColumnAdapter("profile_change","人事资料变更批次",current,json,Set.of("profile:review"),Set.of(),
                id->{var batch=changes.hrBatchDetail(id);return Map.of("id",batch.batchId(),"itemCount",batch.itemCount());},List.of(new FactDefinition("itemCount","变更项数",false)));
    }
    @Bean public PlatformColumnResourceAdapter ownProfileChangePlatformColumns() {
        return new ReadOnlyPlatformColumnAdapter("profile_change_self","本人资料变更批次",current,json,Set.of("profile:edit:self"),Set.of(),
                id->{var batch=changes.myBatchDetail(id);return Map.of("id",batch.batchId(),"itemCount",batch.itemCount());},List.of(new FactDefinition("itemCount","变更项数",false)));
    }
}
