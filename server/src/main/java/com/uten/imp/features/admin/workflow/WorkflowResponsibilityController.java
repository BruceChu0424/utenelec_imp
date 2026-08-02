package com.uten.imp.features.admin.workflow;

import com.uten.imp.features.admin.workflow.WorkflowResponsibilityContracts.Responsibility;
import com.uten.imp.features.admin.workflow.WorkflowResponsibilityContracts.Reviewer;
import com.uten.imp.features.admin.workflow.WorkflowResponsibilityContracts.UpdateRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/admin/workflow-responsibilities")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('workflow_assignment:manage')")
public class WorkflowResponsibilityController {

    private final WorkflowResponsibilityService service;

    @GetMapping
    public List<Responsibility> list() {
        return service.list();
    }

    @GetMapping("/reviewers")
    public List<Reviewer> reviewers() {
        return service.reviewers();
    }

    @PutMapping("/{behaviorCode}")
    public Responsibility update(
            @PathVariable String behaviorCode,
            @Valid @RequestBody UpdateRequest request) {
        return service.update(behaviorCode, request);
    }
}
