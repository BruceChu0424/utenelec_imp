package com.uten.imp.features.subcontract.material_issue;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;
import static com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundContracts.*;

@RestController
@RequestMapping("/api/subcontract/material-issues/{id}/selected-outbound")
@RequiredArgsConstructor
public class SubcontractSelectedOutboundController {
    private final SubcontractSelectedOutboundService service;

    @GetMapping("/review")
    @PreAuthorize("hasAuthority('subcontract_material_issue:view') and hasAuthority('subcontract_outbound:view')")
    public Review review(@PathVariable UUID id) { return service.review(id); }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit') and hasAuthority('subcontract_material_issue:approve') and hasAuthority('subcontract_outbound:execute') and hasAuthority('subcontract_outbound:view') and hasAuthority('subcontract_material_issue:view')")
    public Result execute(@PathVariable UUID id, @Valid @RequestBody Request request) { return service.execute(id, request); }

    @GetMapping("/receipt")
    @PreAuthorize("hasAuthority('subcontract_material_issue:view') and hasAuthority('subcontract_outbound:view')")
    public Receipt receipt(@PathVariable UUID id, @RequestParam String idempotencyKey) { return new Receipt(service.receipt(id, idempotencyKey)); }
}
