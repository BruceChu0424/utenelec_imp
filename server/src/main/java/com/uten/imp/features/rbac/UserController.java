package com.uten.imp.features.rbac;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.rbac.dto.PermissionDto;
import com.uten.imp.features.rbac.dto.RoleDto;
import com.uten.imp.features.rbac.dto.SetRolesRequest;
import com.uten.imp.features.rbac.dto.UserSummary;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/admin")
@RequiredArgsConstructor
public class UserController {

    private final UserService userService;
    private final RoleRepository roleRepo;
    private final PermissionRepository permRepo;

    @GetMapping("/users")
    @PreAuthorize("hasAuthority('user:manage')")
    public PageResponse<UserSummary> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String search,
            @RequestParam(required = false) String status) {
        return userService.list(page, size, search, status);
    }

    @PostMapping("/users/{id}/lock")
    @PreAuthorize("hasAuthority('user:manage')")
    public void lock(@PathVariable UUID id) {
        userService.setStatus(id, "locked");
    }

    @PostMapping("/users/{id}/unlock")
    @PreAuthorize("hasAuthority('user:manage')")
    public void unlock(@PathVariable UUID id) {
        userService.unlock(id);
    }

    @PostMapping("/users/{id}/disable")
    @PreAuthorize("hasAuthority('user:manage')")
    public void disable(@PathVariable UUID id) {
        userService.setStatus(id, "disabled");
    }

    @PostMapping("/users/{id}/enable")
    @PreAuthorize("hasAuthority('user:manage')")
    public void enable(@PathVariable UUID id) {
        userService.setStatus(id, "active");
    }

    @PostMapping("/users/{id}/reset-password")
    @PreAuthorize("hasAuthority('user:manage')")
    public void resetPassword(@PathVariable UUID id) {
        userService.resetPassword(id);
    }

    @PutMapping("/users/{id}/roles")
    @PreAuthorize("hasAuthority('user:manage')")
    public void assignRoles(@PathVariable UUID id, @RequestBody SetRolesRequest req) {
        userService.assignRoles(id, req.roles() == null ? List.of() : req.roles());
    }

    @GetMapping("/roles")
    @PreAuthorize("hasAuthority('user:manage')")
    public List<RoleDto> roles() {
        return roleRepo.findAll().stream().map(RoleDto::of).toList();
    }

    @GetMapping("/permissions")
    @PreAuthorize("hasAuthority('user:manage')")
    public List<PermissionDto> permissions() {
        return permRepo.findAll().stream().map(PermissionDto::of).toList();
    }
}
