package com.uten.imp.features.history;

import com.uten.imp.audit.AuditDetailViewRecorder;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/admin/permission-history")
public class PermissionHistoryController extends ScopedRecordHistoryController {
    public PermissionHistoryController(ScopedRecordHistoryService service, AuditDetailViewRecorder audit) {
        super(service,ScopedRecordHistoryService.Area.PERMISSIONS,audit);
    }
}
