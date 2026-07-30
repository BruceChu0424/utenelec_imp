package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.DepartmentPermissionsDto;
import com.uten.imp.features.admin.dto.EffectivePermissionsDto;
import com.uten.imp.features.admin.dto.PermissionCatalogDto;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermission;
import com.uten.imp.features.rbac.DepartmentPermissionId;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 权限目录 / 部门直配权限点 / 用户有效权限分解（管理端）。
 * 与角色管理同属 user:manage 管控；部门直配权限点不涉及 admin 角色提权，无需 AdminGrantGuard。
 */
@Service
@RequiredArgsConstructor
public class DepartmentPermissionAdminService {

    private final PermissionRepository permissionRepo;
    private final DepartmentRepository departmentRepo;
    private final DepartmentPermissionRepository departmentPermissionRepo;
    private final PermissionResolver permissionResolver;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final AdminUserSupport support;
    private final EmployeeRepository employeeRepo;
    private final RefreshTokenRepository refreshTokenRepo;

    /**
     * 完整权限目录：按 category 分组，组内 sort_order + code 升序；
     * 组间按"组内最小 sort_order → category 名"排序，保证新分组（财税部等）排在默认 0 的老分组之后仍稳定。
     */
    @Transactional(readOnly = true)
    public List<PermissionCatalogDto> catalog() {
        Map<String, List<Permission>> byCategory = permissionRepo.findAll().stream()
                .collect(Collectors.groupingBy(
                        p -> p.getCategory() == null ? "" : p.getCategory(),
                        LinkedHashMap::new, Collectors.toList()));
        record Group(String category, int minSort, List<PermissionCatalogDto.Item> items) {}
        List<Group> groups = new ArrayList<>();
        for (Map.Entry<String, List<Permission>> entry : byCategory.entrySet()) {
            List<Permission> perms = entry.getValue().stream()
                    .sorted(Comparator.comparingInt((Permission p) -> p.getSortOrder() == null ? 0 : p.getSortOrder())
                            .thenComparing(Permission::getCode))
                    .toList();
            int minSort = perms.isEmpty() ? 0
                    : (perms.get(0).getSortOrder() == null ? 0 : perms.get(0).getSortOrder());
            groups.add(new Group(entry.getKey(), minSort,
                    perms.stream().map(p -> new PermissionCatalogDto.Item(p.getCode(), p.getName())).toList()));
        }
        groups.sort(Comparator.comparingInt(Group::minSort).thenComparing(Group::category));
        return groups.stream().map(g -> new PermissionCatalogDto(g.category(), g.items())).toList();
    }

    /** 某部门已直配的权限点 code 列表。 */
    @Transactional(readOnly = true)
    public DepartmentPermissionsDto getDepartmentPermissions(UUID departmentId) {
        requireDepartment(departmentId);
        List<String> codes = departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId)
                .stream().sorted().toList();
        return new DepartmentPermissionsDto(codes);
    }

    /**
     * 整体替换某部门的直配权限点（事务内 delete + insert，风格参照 RoleAdminService.setDepartmentRoles）。
     *
     * <p>未知 code 处理策略：<b>报错拒绝</b>（与 PermissionOverrideAdminService.setPermissionOverrides 一致）。
     * 理由：静默忽略会让管理员误以为保存成功，实际权限被丢弃；前端传错 code 属于调用方 bug，应尽早暴露。
     *
     * <p>不涉及 admin 角色提权（权限点 ≠ admin 角色），按任务约定不加 AdminGrantGuard。
     */
    @Transactional
    public void setDepartmentPermissions(UUID departmentId, List<String> permissionCodes) {
        tx.bind();
        requireDepartment(departmentId);
        // 去重（保持顺序），避免主键冲突
        Set<String> codes = new LinkedHashSet<>(permissionCodes == null ? List.of() : permissionCodes);
        Map<String, Permission> byCode = permissionRepo.findByCodeIn(codes).stream()
                .collect(Collectors.toMap(Permission::getCode, p -> p));
        for (String code : codes) {
            if (!byCode.containsKey(code)) {
                throw new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code);
            }
        }
        UUID actor = currentUser.id().orElse(null);
        departmentPermissionRepo.deleteByIdDepartmentId(departmentId);
        for (String code : codes) {
            DepartmentPermission dp = new DepartmentPermission();
            dp.setId(new DepartmentPermissionId(departmentId, byCode.get(code).getId()));
            dp.setCreatedBy(actor);
            departmentPermissionRepo.save(dp);
        }
        // 权限变更即时生效：吊销该部门子树（含下级部门）所有用户的 refresh token。
        // access token 到期（≤15 分钟）后强制重新登录，新权限随新令牌下发；
        // 避免"权限已收回但用户带着旧令牌继续用"的窗口。
        for (UUID uid : employeeRepo.findUserIdsByDepartmentSubtree(departmentId)) {
            refreshTokenRepo.revokeAllByUserId(uid);
        }
    }

    /** 某用户的有效权限分解（复用 PermissionResolver 的合成逻辑，单一事实来源）。 */
    @Transactional(readOnly = true)
    public EffectivePermissionsDto effectivePermissions(UUID userId) {
        UserAccount target = support.require(userId);
        PermissionResolver.PermBreakdown b = permissionResolver.breakdownOf(target);
        return new EffectivePermissionsDto(
                b.departmentId(),
                b.departmentName(),
                b.departmentPermissions().stream().sorted().toList(),
                b.baselinePermissions().stream().sorted().toList(),
                b.grants().stream().sorted().toList(),
                b.revokes().stream().sorted().toList(),
                b.effective().stream().sorted().toList(),
                target.isSuperAdmin());
    }

    private void requireDepartment(UUID departmentId) {
        departmentRepo.findById(departmentId).filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
    }
}
