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
    public EmployeeOnboardingResult onboard(@Valid @RequestBody OnboardingRequest req) {
        return onboardingService.onboard(req);
    }

    @PostMapping("/{id}/account")
    @PreAuthorize("hasAuthority('account:support')")
    public EmployeeOnboardingResult provisionAccount(@PathVariable UUID id) {
        // 给批量导入等「未开通账号」的存量员工补开登录账号（账号=手机号，初始密码=身份证后6位）。
        return onboardingService.provisionAccount(id);
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
    public void confirm(@PathVariable UUID id,
                        @RequestBody(required = false) ConfirmRequest req) {
        commandService.confirm(id, req == null ? null : req.confirmedDate());
    }

    @PostMapping("/{id}/change-phone")
    @PreAuthorize("hasAuthority('employee:pii:edit')")
    public void changePhone(@PathVariable UUID id, @Valid @RequestBody ChangePhoneRequest req) {
        commandService.changePhone(id, req.newPhone());
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
