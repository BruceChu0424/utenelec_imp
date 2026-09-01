package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.analysis.SubcontractPreparationContracts.StartRequest;
import com.uten.imp.features.production.analysis.SubcontractPreparationContracts.StartResult;
import com.uten.imp.features.production.analysis.SubcontractPreparationContracts.Task;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/production/material-analyses/subcontract-preparations")
@RequiredArgsConstructor
public class SubcontractPreparationController {
    private final SubcontractPreparationCoordinator coordinator;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_preparation:view')")
    public PageResponse<Task> tasks(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID planItemId,
            @RequestParam(required = false) UUID sourceAnalysisId,
            @RequestParam(required = false) UUID sourceMaterialLineId) {
        return coordinator.tasks(page, size, status, keyword, planItemId,
                sourceAnalysisId, sourceMaterialLineId);
    }

    @PostMapping("/{planItemId}/start")
    @PreAuthorize("hasAuthority('subcontract_preparation:view')"
            + " and hasAuthority('subcontract_preparation:start')")
    public StartResult start(
            @PathVariable UUID planItemId,
            @Valid @RequestBody StartRequest request) {
        return coordinator.start(planItemId, request);
    }
}
