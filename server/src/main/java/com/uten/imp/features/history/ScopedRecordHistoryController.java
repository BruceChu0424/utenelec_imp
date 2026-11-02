package com.uten.imp.features.history;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.history.RecordHistory;
import com.uten.imp.security.AuthUser;
import java.util.UUID;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

/** One transport contract for both scoped history consumers. */
public abstract class ScopedRecordHistoryController {
    private final ScopedRecordHistoryService service;
    private final ScopedRecordHistoryService.Area area;
    private final AuditDetailViewRecorder audit;
    protected ScopedRecordHistoryController(ScopedRecordHistoryService service,
            ScopedRecordHistoryService.Area area, AuditDetailViewRecorder audit) {
        this.service=service; this.area=area; this.audit=audit;
    }
    @GetMapping
    @PreAuthorize("isAuthenticated() and this.historyReadable(principal)")
    public RecordHistory.Page list(@RequestParam(required=false) String entityType,
            @RequestParam(required=false) UUID recordId, @RequestParam(required=false) Long cursor,
            @RequestParam(required=false) String action, @RequestParam(required=false) String actorKeyword,
            @RequestParam(required=false) String keyword, @RequestParam(required=false) String dateFrom,
            @RequestParam(required=false) String dateTo, @RequestParam(required=false) String sourceType,
            @RequestParam(required=false) String summaryKeyword, @RequestParam(defaultValue="50") int size) {
        return service.search(area,new ScopedRecordHistoryService.Filters(entityType,recordId,cursor,action,
                actorKeyword,keyword,dateFrom,dateTo,sourceType,summaryKeyword,size));
    }
    @GetMapping("/{id}")
    @PreAuthorize("isAuthenticated() and this.historyReadable(principal)")
    public RecordHistory.Entry detail(@PathVariable long id) {
        var result=service.detail(area,id);
        audit.record(area==ScopedRecordHistoryService.Area.COMPANY_FILES ? "view_company_file_history_detail" : "view_permission_history_detail",
                area==ScopedRecordHistoryService.Area.COMPANY_FILES ? "company_file_nodes" : "permissions",
                result.recordId(),null,null,"修改历史 · "+result.recordLabel());
        return result;
    }
    public boolean historyReadable(Object principal) {
        return principal instanceof AuthUser user && ScopedRecordHistoryService.canRead(area,user);
    }
}
