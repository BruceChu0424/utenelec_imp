package com.uten.imp.features.org.employee;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.UserAccountAdminService;
import com.uten.imp.features.org.employee.dto.*;
import com.uten.imp.responsibility.DataHandoverService;
import com.uten.imp.responsibility.dto.DataHandoverPreview;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Set;
import java.util.UUID;

/** 员工档案与生命周期接口（/api/org/employees）：入职/转正/调岗/离职/复用 + 账号开通与锁定。 */
@RestController
@RequestMapping("/api/org/employees")
@RequiredArgsConstructor
public class EmployeeController {

    private final EmployeeQueryService queryService;
    private final EmployeeOnboardingService onboardingService;
    private final EmployeeCommandService commandService;
    private final UserAccountAdminService userAccountAdminService;
    private final DataHandoverService dataHandoverService;
    private final AuditDetailViewRecorder viewAudit;

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
        EmployeeDetail detail = queryService.detail(id);
        viewAudit.record(
                "view_employee_detail", "employees", id,
                detail.getCode(), null, "员工档案");
        return detail;
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

    @PostMapping("/{id}/account/lock")
    @PreAuthorize("hasAuthority('account:support')")
    public void lockAccount(@PathVariable UUID id) {
        // 员工详情顶卡：锁定已开通的登录账号（与开通账号同权限级 account:support）。
        userAccountAdminService.lockByEmployee(id);
    }

    @PostMapping("/{id}/account/unlock")
    @PreAuthorize("hasAuthority('account:support')")
    public void unlockAccount(@PathVariable UUID id) {
        // 员工详情顶卡：解锁被锁定的登录账号。
        userAccountAdminService.unlockByEmployee(id);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('employee:edit')")
    public EmployeeDetail update(@PathVariable UUID id, @Valid @RequestBody UpdateEmployeeRequest req) {
        return commandService.update(id, req);
    }

    @PostMapping("/{id}/transfer")
    @PreAuthorize("hasAuthority('employee:transfer')")
    public void transfer(@PathVariable UUID id, @Valid @RequestBody TransferRequest req) {
        commandService.transfer(id, req);
    }

    @GetMapping("/{id}/handover-preview")
    @PreAuthorize("hasAnyAuthority('employee:handover', 'employee:offboard') or (principal.superAdmin and hasAuthority('authorization:manage'))")
    public DataHandoverPreview handoverPreview(
            @PathVariable UUID id,
            @RequestParam(required = false) UUID successorEmployeeId) {
        return dataHandoverService.previewOffboarding(id, successorEmployeeId);
    }

    @PostMapping("/{id}/offboard")
    @PreAuthorize("hasAuthority('employee:offboard')")
    public void offboard(@PathVariable UUID id, @Valid @RequestBody OffboardRequest req) {
        commandService.offboard(id, req);
    }

    @PostMapping("/{id}/confirm")
    @PreAuthorize("hasAuthority('employee:confirm')")
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
    @PreAuthorize("hasAuthority('employee:rehire')")
    public void rehire(@PathVariable UUID id) {
        commandService.rehire(id);
    }

    /** 续签/补录合同（HR）。 */
    @PostMapping("/{id}/contracts")
    @PreAuthorize("hasAuthority('employee:contract_renew')")
    public void renewContract(@PathVariable UUID id, @Valid @RequestBody RenewContractRequest req) {
        commandService.renewContract(id, req);
    }

    /** 设置员工头像（HR；附件须为该员工的图片）。 */
    @PostMapping("/{id}/avatar")
    @PreAuthorize("hasAuthority('employee:avatar_edit')")
    public void setAvatar(@PathVariable UUID id, @Valid @RequestBody SetAvatarRequest req) {
        commandService.setAvatar(id, req);
    }

    // 注：禁止删除员工。员工离职走 POST /{id}/offboard（status='resigned' 永久留存），
    // 不提供物理/软删除端点，也不再有 employee:delete 权限（V280 已下线）。
}
