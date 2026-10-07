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
    private final AiUsageDashboardService dashboard;
    public AiUsageAuditController(AiUsageAdminAccess access, AiUsageAuditService usage,
                                  AiProviderBillingService billing, AiUsageDashboardService dashboard) {
        this.access = access; this.usage = usage; this.billing = billing; this.dashboard = dashboard;
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

    /** AI 用量看板(ADR-164): 窗口序列 + 按人聚合 + 今日 KPI。 */
    @GetMapping("/usage-dashboard")
    public AiUsageDtos.Dashboard dashboard(@RequestParam(defaultValue="day") String window) {
        access.require(); return dashboard.dashboard(window);
    }
    /** 人员明细: 同窗口的个人序列、用途/服务商分布与最近使用。 */
    @GetMapping("/usage-people/{userId}")
    public AiUsageDtos.PersonDetail person(@PathVariable UUID userId,
            @RequestParam(defaultValue="day") String window) {
        access.require(); return dashboard.person(userId, window);
    }
    /** 保存按人限额与停用(乐观锁; 审计由服务随事务记录)。 */
    @PutMapping("/usage-people/{userId}/limits")
    @RequiresStepUp
    public AiUserLimitsService.Limits saveLimits(@PathVariable UUID userId,
            @RequestBody AiUsageDtos.LimitsRequest request) {
        return dashboard.saveLimits(userId, request, access.require());
    }
}
