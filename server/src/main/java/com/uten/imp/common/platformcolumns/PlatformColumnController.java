package com.uten.imp.common.platformcolumns;

import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.UUID;
import static com.uten.imp.common.platformcolumns.PlatformColumnContracts.*;

@RestController
@RequestMapping("/api/platform-columns")
@RequiredArgsConstructor
public class PlatformColumnController {
    private final PlatformColumnService service;
    private final com.uten.imp.audit.AuditDetailViewRecorder detailViews;
    @GetMapping("/scopes") public List<Scope> scopes() { return service.scopes(); }
    @GetMapping("/{scope}/definitions") public List<Definition> definitions(@PathVariable String scope, @RequestParam(required=false) String q,
            @RequestParam(required=false) List<UUID> ids) { return ids==null?service.search(scope,q):service.definitions(scope,ids); }
    @PostMapping("/{scope}/definitions") public Definition create(@PathVariable String scope,@RequestBody CreateDefinition request) { return service.create(scope,request); }
    @PostMapping("/{scope}/values:batch") public List<Row> read(@PathVariable String scope,@RequestBody BatchRead request) { return service.read(scope,request); }
    @PutMapping("/{scope}/values/{recordId}") public Row write(@PathVariable String scope,@PathVariable UUID recordId,@RequestBody Write request) { return service.write(scope,recordId,request); }
    @GetMapping("/{scope}/values/{recordId}/history") public List<HistoryRow> history(@PathVariable String scope,@PathVariable UUID recordId,
            @RequestParam(required=false) Long beforeId,@RequestParam(defaultValue="20") int size){
        var result=service.history(scope,recordId,beforeId,size);
        detailViews.record("view_platform_field_history_detail","platform_record_fields",recordId,null,null,"业务扩展字段历史");return result;
    }
    @PostMapping("/{scope}/definitions/{definitionId}/use") public void used(@PathVariable String scope,@PathVariable UUID definitionId) { service.used(scope,definitionId); }
}
