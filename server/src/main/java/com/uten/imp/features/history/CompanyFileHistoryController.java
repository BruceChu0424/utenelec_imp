package com.uten.imp.features.history;

import com.uten.imp.audit.AuditDetailViewRecorder;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/company-files/record-history")
public class CompanyFileHistoryController extends ScopedRecordHistoryController {
    public CompanyFileHistoryController(ScopedRecordHistoryService service, AuditDetailViewRecorder audit) {
        super(service,ScopedRecordHistoryService.Area.COMPANY_FILES,audit);
    }
}
