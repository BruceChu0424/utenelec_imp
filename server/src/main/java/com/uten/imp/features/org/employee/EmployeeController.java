package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.org.employee.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Set;
import java.util.UUID;

@RestController
@RequestMapping("/api/org/employees")
@RequiredArgsConstructor
public class EmployeeController {

    private final EmployeeQueryService queryService;
    private final EmployeeOnboardingService onboardingService;
    private final EmployeeCommandService commandService;

    @GetMapping
    @PreAuthorize("hasAuthority('employee:view')")
    public PageResponse<EmployeeListItem> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String search,
            @RequestParam(required = false) Set<String> statuses,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "false") boolean includeSubtree) {
        return queryService.list(page, size, search, statuses, departmentId, includeSubtree);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('employee:view')")
    public EmployeeDetail detail(@PathVariable UUID id) {
        return queryService.detail(id);
    }

    @GetMapping("/{id}/history")
    @PreAuthorize("hasAuthority('employee:view')")
    public List<NestedDtos.EmploymentHistoryDto> history(@PathVariable UUID id) {
        return commandService.history(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('employee:create')")
    public EmployeeDetail onboard(@Valid @RequestBody OnboardingRequest req) {
        return onboardingService.onboard(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('employee:edit')")
    public EmployeeDetail update(@PathVariable UUID id, @Valid @RequestBody UpdateEmployeeRequest req) {
        return commandService.update(id, req);
    }

    @PostMapping("/{id}/transfer")
    @PreAuthorize("hasAuthority('employee:edit')")
    public void transfer(@PathVariable UUID id, @Valid @RequestBody TransferRequest req) {
        commandService.transfer(id, req);
    }

    @PostMapping("/{id}/offboard")
    @PreAuthorize("hasAuthority('employee:edit')")
    public void offboard(@PathVariable UUID id, @Valid @RequestBody OffboardRequest req) {
        commandService.offboard(id, req);
    }

    @PostMapping("/{id}/confirm")
    @PreAuthorize("hasAuthority('employee:edit')")
    public void confirm(@PathVariable UUID id) {
        commandService.confirm(id);
    }

    @PostMapping("/{id}/rehire")
    @PreAuthorize("hasAuthority('employee:edit')")
    public void rehire(@PathVariable UUID id) {
        commandService.rehire(id);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('employee:delete')")
    public void delete(@PathVariable UUID id) {
        commandService.delete(id);
    }
}
