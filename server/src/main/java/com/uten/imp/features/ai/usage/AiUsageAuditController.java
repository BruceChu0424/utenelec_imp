package com.uten.imp.features.ai.usage;

import com.uten.imp.security.RequiresStepUp;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;

@RestController
@RequestMapping("/api/admin/ai")
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class AiUsageAuditController {
    private final AiUsageAdminAccess access;
    private final AiUsageAuditService usage;
    private final AiProviderBillingService billing;
    public AiUsageAuditController(AiUsageAdminAccess access, AiUsageAuditService usage, AiProviderBillingService billing) {
        this.access = access; this.usage = usage; this.billing = billing;
    }
    @GetMapping("/usage-audit")
    public AiUsageDtos.Audit usage(@RequestParam(defaultValue="30") int days, @RequestParam(defaultValue="0") int page,
            @RequestParam(defaultValue="20") int size, @RequestParam(required=false) UUID userId,
            @RequestParam(required=false) UUID providerId) {
        access.require(); return usage.query(days, page, size, userId, providerId);
    }
    @GetMapping("/providers/{id}/billing")
    public AiUsageDtos.Billing billing(@PathVariable UUID id) { access.require(); return billing.get(id); }
    @PutMapping("/providers/{id}/billing")
    @RequiresStepUp
    public AiUsageDtos.Billing save(@PathVariable UUID id, @RequestBody AiUsageDtos.BillingRequest request) {
        access.require(); return billing.save(id, request);
    }
}
