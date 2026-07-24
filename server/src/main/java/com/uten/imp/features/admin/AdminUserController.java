package com.uten.imp.features.admin;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.dto.DepartmentRolesDto;
import com.uten.imp.features.admin.dto.PermissionDto;
import com.uten.imp.features.admin.dto.PermissionOverridesDto;
import com.uten.imp.features.admin.dto.RoleDto;
import com.uten.imp.features.admin.dto.SetRolesRequest;
import com.uten.imp.features.admin.dto.UserSummary;
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

    @GetMapping("/users")
    @PreAuthorize("hasAuthority('user:manage')")
    public PageResponse<UserSummary> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String search,
            @RequestParam(required = false) String status) {
        return userAccountAdmin.list(page, size, search, status);
    }

    @PostMapping("/users/{id}/lock")
    @PreAuthorize("hasAuthority('user:manage')")
    public void lock(@PathVariable UUID id) {
        userAccountAdmin.setStatus(id, "locked");
    }

    @PostMapping("/users/{id}/unlock")
    @PreAuthorize("hasAuthority('user:manage')")
    public void unlock(@PathVariable UUID id) {
        userAccountAdmin.unlock(id);
    }

    @PostMapping("/users/{id}/disable")
    @PreAuthorize("hasAuthority('user:manage')")
    public void disable(@PathVariable UUID id) {
        userAccountAdmin.setStatus(id, "disabled");
    }

    @PostMapping("/users/{id}/enable")
    @PreAuthorize("hasAuthority('user:manage')")
    public void enable(@PathVariable UUID id) {
        userAccountAdmin.setStatus(id, "active");
    }

    @PostMapping("/users/{id}/reset-password")
    @PreAuthorize("hasAuthority('user:manage')")
    public void resetPassword(@PathVariable UUID id) {
        userAccountAdmin.resetPassword(id);
    }

    @PutMapping("/users/{id}/roles")
    @PreAuthorize("hasAuthority('user:manage')")
    public void assignRoles(@PathVariable UUID id, @RequestBody SetRolesRequest req) {
        roleAdmin.assignRoles(id, req.roles() == null ? List.of() : req.roles());
    }

    @GetMapping("/roles")
    @PreAuthorize("hasAuthority('user:manage')")
    public List<RoleDto> roles() {
        return roleAdmin.listRoles();
    }

    @GetMapping("/permissions")
    @PreAuthorize("hasAuthority('user:manage')")
    public List<PermissionDto> permissions() {
        return roleAdmin.listPermissions();
    }

    @GetMapping("/department-roles")
    @PreAuthorize("hasAuthority('user:manage')")
    public List<DepartmentRolesDto> departmentRoles() {
        return roleAdmin.listDepartmentRoles();
    }

    @PutMapping("/departments/{id}/roles")
    @PreAuthorize("hasAuthority('user:manage')")
    public void setDepartmentRoles(@PathVariable UUID id, @RequestBody SetRolesRequest req) {
        roleAdmin.setDepartmentRoles(id, req.roles() == null ? List.of() : req.roles());
    }

    @GetMapping("/users/{id}/permission-overrides")
    @PreAuthorize("hasAuthority('user:manage')")
    public PermissionOverridesDto getPermissionOverrides(@PathVariable UUID id) {
        return permissionOverrideAdmin.getPermissionOverrides(id);
    }

    @PutMapping("/users/{id}/permission-overrides")
    @PreAuthorize("hasAuthority('user:manage')")
    public void setPermissionOverrides(@PathVariable UUID id, @RequestBody PermissionOverridesDto req) {
        permissionOverrideAdmin.setPermissionOverrides(id,
                req.grants() == null ? List.of() : req.grants(),
                req.revokes() == null ? List.of() : req.revokes());
    }
}
