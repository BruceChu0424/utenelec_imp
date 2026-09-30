package com.uten.imp.features.rd_task;

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
public class RdTaskPlatformColumnAdapters {
    private final RdTaskService tasks;private final SecurityContextCurrentUser current;private final ObjectMapper json;
    @Bean public PlatformColumnResourceAdapter rdTaskPlatformColumns() {
        return new ReadOnlyPlatformColumnAdapter("rd_task","研发任务",current,json,Set.of("rd_task:view"),Set.of(),
                id->{var task=tasks.get(id);var facts=new HashMap<String,Object>();facts.put("id",task.id());facts.put("rowVersion",task.rowVersion());
                    if(task.dueDate()!=null)facts.put("daysUntilDue",java.time.temporal.ChronoUnit.DAYS.between(com.uten.imp.common.time.BusinessTime.today(),task.dueDate()));return facts;},
                List.of(new FactDefinition("daysUntilDue","距离到期天数",false),new FactDefinition("rowVersion","记录版本",false)));
    }
}
