package com.uten.imp.features.admin;

import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.dto.PermissionDto;
import com.uten.imp.features.admin.dto.PermissionOverridesDto;
import com.uten.imp.features.admin.dto.UserSummary;
import com.uten.imp.features.admin.dto.TemporaryPasswordResponse;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/admin")
@RequiredArgsConstructor
public class AdminUserController {

    private final UserAccountAdminService userAccountAdmin;
    private final RoleAdminService roleAdmin;
    private final PermissionOverrideAdminService permissionOverrideAdmin;
    private final DataScopeAdminService dataScopeAdmin;

    @GetMapping("/users")
    @PreAuthorize("hasAuthority('account:support')")
    public PageResponse<UserSummary> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String search,
            @RequestParam(required = false) String status) {
        return userAccountAdmin.list(page, size, search, status);
    }

    @GetMapping("/users/by-employee/{employeeId}")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public UserSummary byEmployee(@PathVariable UUID employeeId) {
        return userAccountAdmin.getByEmployeeId(employeeId);
    }

    @PostMapping("/users/{id}/lock")
    @PreAuthorize("hasAuthority('account:support')")
    public void lock(@PathVariable UUID id) {
        userAccountAdmin.setStatus(id, "locked");
    }

    @PostMapping("/users/{id}/unlock")
    @PreAuthorize("hasAuthority('account:support')")
    public void unlock(@PathVariable UUID id) {
        userAccountAdmin.unlock(id);
    }

    @PostMapping("/users/{id}/disable")
    @PreAuthorize("hasAuthority('account:support')")
    public void disable(@PathVariable UUID id) {
        userAccountAdmin.setStatus(id, "disabled");
    }

    @PostMapping("/users/{id}/enable")
    @PreAuthorize("hasAuthority('account:support')")
    public void enable(@PathVariable UUID id) {
        userAccountAdmin.setStatus(id, "active");
    }

    @PostMapping("/users/{id}/reset-password")
    @PreAuthorize("hasAuthority('account:support')")
    public TemporaryPasswordResponse resetPassword(@PathVariable UUID id) {
        return new TemporaryPasswordResponse(userAccountAdmin.resetPassword(id));
    }

    // 角色体系已下线（ADR-011/V29）：角色分配相关端点（/users/{id}/roles、/roles、
    // /department-roles、/departments/{id}/roles）已移除，权限只走
    // 部门配置（AdminPermissionController）+ 个人覆盖（下方端点）。

    @GetMapping("/permissions")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<PermissionDto> permissions() {
        return roleAdmin.listPermissions();
    }

    @GetMapping("/users/{id}/permission-overrides")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public PermissionOverridesDto getPermissionOverrides(@PathVariable UUID id) {
        return permissionOverrideAdmin.getPermissionOverrides(id);
    }

    @PutMapping("/users/{id}/permission-overrides")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public void setPermissionOverrides(
            @PathVariable UUID id, @Valid @RequestBody PermissionOverridesDto req) {
        permissionOverrideAdmin.setPermissionOverrides(id,
                req.grants() == null ? List.of() : req.grants(),
                req.revokes() == null ? List.of() : req.revokes());
    }

    // ===== 数据范围授权（V89：客户/外贸货品「能看哪些业务员的」中间档） =====

    /** 授权归属人候选（该范围内实际有归属数据的员工 + 数量）。 */
    @GetMapping("/data-scope-owners")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<java.util.Map<String, Object>> dataScopeOwners(@RequestParam String scope) {
        return dataScopeAdmin.ownerCandidates(scope);
    }

    /** 某用户在某范围的授权归属人。 */
    @GetMapping("/users/{id}/data-scopes")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<UUID> getDataScopes(@PathVariable UUID id, @RequestParam String scope) {
        return dataScopeAdmin.getDataScopes(id, scope);
    }

    /** 整体替换某用户在某范围的授权归属人。 */
    @PutMapping("/users/{id}/data-scopes")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public void setDataScopes(@PathVariable UUID id, @RequestParam String scope,
                              @Valid @RequestBody DataScopesBody req) {
        dataScopeAdmin.setDataScopes(id, scope, req == null ? List.of() : req.ownerEmployeeIds());
    }

    /** 数据范围整体替换请求体。 */
    public record DataScopesBody(
            @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<UUID> ownerEmployeeIds) {}
}
