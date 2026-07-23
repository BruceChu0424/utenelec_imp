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
import java.util.UUID;

/**
 * 访客审批接口（HR/被访人，staff 主体）。
 * GET  /api/visitor-approval            待审批列表（HR）
 * GET  /api/visitor-approval/as-host    我作为接待人的待确认列表（被访人）
 * GET  /api/visitor-approval/{id}       详情
 * POST /api/visitor-approval/{id}/action      approve/reject/forward
 * POST /api/visitor-approval/{id}/host-confirm 被访人确认
 */
@RestController
@RequestMapping("/api/visitor-approval")
@RequiredArgsConstructor
public class VisitorApprovalController {

    private final VisitorApprovalService service;

    @GetMapping
    @PreAuthorize("hasAuthority('visitor:approve')")
    public List<VisitorListItem> list(@RequestParam(required = false) String status) {
        return service.listForApproval(status);
    }

    @GetMapping("/as-host")
    @PreAuthorize("hasAuthority('visitor:host-confirm')")
    public List<VisitorListItem> asHost() {
        return service.myAsHost();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('visitor:host-confirm')")
    public VisitorDetail detail(@PathVariable UUID id) {
        return service.getDetailForStaff(id);
    }

    @PostMapping("/{id}/action")
    @PreAuthorize("hasAuthority('visitor:approve')")
    public VisitorDetail action(@PathVariable UUID id, @RequestBody VisitorApproveRequest req) {
        return service.handleAction(id, req);
    }

    @PostMapping("/{id}/host-confirm")
    @PreAuthorize("hasAuthority('visitor:host-confirm')")
    public VisitorDetail hostConfirm(@PathVariable UUID id, @RequestBody HostConfirmRequest req) {
        return service.hostConfirm(id, req);
    }
}
