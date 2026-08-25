package com.uten.imp.responsibility;

import com.uten.imp.responsibility.dto.DataHandoverCandidatePage;
import com.uten.imp.responsibility.dto.DataHandoverPreview;
import com.uten.imp.responsibility.dto.DataHandoverRequest;
import com.uten.imp.responsibility.dto.DataHandoverResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Set;
import java.util.UUID;

/** Administrative API for previewing and atomically executing employee responsibility handovers. */
@RestController
@RequestMapping("/api/admin/data-handovers")
@RequiredArgsConstructor
public class DataHandoverAdminController {

    private final DataHandoverService service;
    private final DataHandoverCandidateService candidates;

    @GetMapping("/preview")
    @PreAuthorize("hasAuthority('employee:handover') or (principal.superAdmin and hasAuthority('authorization:manage'))")
    public DataHandoverPreview preview(
            @RequestParam UUID sourceEmployeeId,
            @RequestParam(required = false) UUID targetEmployeeId,
            @RequestParam(required = false) Set<String> scopes) {
        return service.preview(sourceEmployeeId, targetEmployeeId, scopes);
    }

    @GetMapping("/candidates")
    @PreAuthorize("hasAnyAuthority('employee:handover','employee:offboard') or (principal.superAdmin and hasAuthority('authorization:manage'))")
    public DataHandoverCandidatePage candidates(
            @RequestParam String role,
            @RequestParam(required = false, defaultValue = "") String query,
            @RequestParam(required = false, defaultValue = "1") int page,
            @RequestParam(required = false, defaultValue = "20") int size) {
        return candidates.search(role, query, page, size);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('employee:handover') or (principal.superAdmin and hasAuthority('authorization:manage'))")
    public DataHandoverResult execute(@Valid @RequestBody DataHandoverRequest request) {
        return service.executeManual(request);
    }
}
