package com.uten.imp.features.visitor;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.*;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;
import java.util.HashMap;

@Configuration
@RequiredArgsConstructor
public class VisitorPlatformColumnAdapters {
    private final VisitorHrApprovalService visitors;private final SecurityContextCurrentUser current;private final ObjectMapper json;
    @Bean public PlatformColumnResourceAdapter visitorApplicationPlatformColumns() {
        return new ReadOnlyPlatformColumnAdapter("visitor_application","访客申请",current,json,Set.of("visitor:approve","visitor:host_confirm"),Set.of(),
                id->{var visit=visitors.getDetailForStaff(id);var facts=new HashMap<String,Object>();facts.put("id",visit.id());
                    if(visit.plannedVisitAt()!=null&&visit.plannedLeaveAt()!=null)facts.put("plannedDurationSeconds",java.time.Duration.between(visit.plannedVisitAt(),visit.plannedLeaveAt()).getSeconds());return facts;},
                List.of(new FactDefinition("plannedDurationSeconds","预约时长（秒）",false)));
    }
}
