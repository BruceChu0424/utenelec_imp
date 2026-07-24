package com.uten.imp.features.visitor;

import com.uten.imp.features.visitor.dto.VisitorApplyDto.HostConfirmRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApproveRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 访客审批接口（HR/被访人，staff 主体）。
 * GET  /api/visitor-approval            待审批列表（HR）
 * GET  /api/visitor-approval/as-host    我作为接待人的待确认列表（被访人）
 * GET  /api/visitor-approval/pending-count        HR 待办数（徽章）
 * GET  /api/visitor-approval/host-pending-count   被访人待确认数（徽章）
 * GET  /api/visitor-approval/{id}       详情
 * POST /api/visitor-approval/{id}/action      approve/reject/forward
 * POST /api/visitor-approval/{id}/host-confirm 被访人确认
 */
@RestController
@RequestMapping("/api/visitor-approval")
@RequiredArgsConstructor
public class VisitorApprovalController {

    private final VisitorHrApprovalService hrApprovalService;
    private final VisitorHostConfirmService hostConfirmService;

    @GetMapping
    @PreAuthorize("hasAuthority('visitor:approve')")
    public List<VisitorListItem> list(@RequestParam(required = false) String status) {
        return hrApprovalService.listForApproval(status);
    }

    @GetMapping("/as-host")
    @PreAuthorize("hasAuthority('visitor:host-confirm')")
    public List<VisitorListItem> asHost() {
        return hostConfirmService.myAsHost();
    }

    @GetMapping("/pending-count")
    @PreAuthorize("hasAuthority('visitor:approve')")
    public Map<String, Long> pendingCount() {
        return Map.of("count", hrApprovalService.pendingCount());
    }

    @GetMapping("/host-pending-count")
    @PreAuthorize("hasAuthority('visitor:host-confirm')")
    public Map<String, Long> hostPendingCount() {
        return Map.of("count", hostConfirmService.myAsHostPendingCount());
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('visitor:host-confirm')")
    public VisitorDetail detail(@PathVariable UUID id) {
        return hrApprovalService.getDetailForStaff(id);
    }

    @PostMapping("/{id}/action")
    @PreAuthorize("hasAuthority('visitor:approve')")
    public VisitorDetail action(@PathVariable UUID id, @RequestBody VisitorApproveRequest req) {
        return hrApprovalService.handleAction(id, req);
    }

    @PostMapping("/{id}/host-confirm")
    @PreAuthorize("hasAuthority('visitor:host-confirm')")
    public VisitorDetail hostConfirm(@PathVariable UUID id, @RequestBody HostConfirmRequest req) {
        return hostConfirmService.hostConfirm(id, req);
    }
}
