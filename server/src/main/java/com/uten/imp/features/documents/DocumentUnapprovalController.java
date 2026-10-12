package com.uten.imp.features.documents;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/documents/{family}/{id}")
@PreAuthorize("isAuthenticated()")
@RequiredArgsConstructor
public class DocumentUnapprovalController {
    private final DocumentUnapprovalService service;
    @PostMapping("/unapprove")
    public Object unapprove(@PathVariable String family,@PathVariable UUID id,
            @Valid @RequestBody DocumentUnapprovalService.UnapproveRequest request) {
        return service.unapprove(family,id,request);
    }
    @GetMapping("/unapproval")
    public Map<String,Object> lineage(@PathVariable String family,@PathVariable UUID id) {
        return service.lineage(family,id);
    }
    @GetMapping("/unapproval-capability")
    public DocumentUnapprovalService.UnapprovalCapability capability(@PathVariable String family,@PathVariable UUID id) {
        return service.capability(family,id);
    }
}
