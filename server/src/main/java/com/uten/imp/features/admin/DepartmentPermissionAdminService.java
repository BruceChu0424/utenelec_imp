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
import org.springframework.security.access.prepost.PreAuthorize;
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
 * 授权策略仅允许超级管理员维护；权限点本身就是安全边界。
 */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class DepartmentPermissionAdminService {

    private static final Set<String> INDIVIDUAL_ONLY_PERMISSION_CODES = Set.of(
            "audit_log:view",
            "audit_log:export");

    /**
     * 一级模块的固定显示顺序。未列出的模块（如兜底「其他」）排在最后并按名字稳定排序，
     * 保证权限目录始终以业务主干顺序呈现、新增模块不会随机穿插。
     */
    private static final List<String> MODULE_ORDER = List.of(
            "基础资料", "销售管理", "采购管理", "委外管理", "生产管理",
            "仓库管理", "财税管理", "工程研发", "人事行政", "品质检测", "系统管理");

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
     * 完整权限目录（两级：module → category → 权限项）。
     * 按 (module, category) 分组；module 为空归「其他」。组内权限按 sort_order → code 升序；
     * 组间按「模块在 {@link #MODULE_ORDER} 中的序号（未列出者排最后）→ 组内最小 sort_order → 子类名」稳定排序。
     */
    @Transactional(readOnly = true)
    public List<PermissionCatalogDto> catalog() {
        support.requireCurrentSuperAdmin();
        record GroupKey(String module, String category) {}
        Map<GroupKey, List<Permission>> byGroup = permissionRepo.findAllByActiveTrue().stream()
                .collect(Collectors.groupingBy(
                        p -> new GroupKey(
                                (p.getModule() == null || p.getModule().isBlank()) ? "其他" : p.getModule(),
                                p.getCategory() == null ? "" : p.getCategory()),
                        LinkedHashMap::new, Collectors.toList()));
        record Group(GroupKey key, int minSort, List<PermissionCatalogDto.Item> items) {}
        List<Group> groups = new ArrayList<>();
        for (Map.Entry<GroupKey, List<Permission>> entry : byGroup.entrySet()) {
            List<Permission> perms = entry.getValue().stream()
                    .sorted(Comparator.comparingInt((Permission p) -> p.getSortOrder() == null ? 0 : p.getSortOrder())
                            .thenComparing(Permission::getCode))
                    .toList();
            int minSort = perms.isEmpty() ? 0
                    : (perms.get(0).getSortOrder() == null ? 0 : perms.get(0).getSortOrder());
            groups.add(new Group(entry.getKey(), minSort,
                    perms.stream().map(p -> new PermissionCatalogDto.Item(
                            p.getId(),
                            p.getCode(),
                            p.getName(),
                            normalizedActionType(p.getActionType()),
                            p.getDescription(),
                            p.isAssignable())).toList()));
        }
        groups.sort(Comparator
                .comparingInt((Group g) -> {
                    int idx = MODULE_ORDER.indexOf(g.key().module());
                    return idx < 0 ? MODULE_ORDER.size() : idx;
                })
                .thenComparingInt(Group::minSort)
                .thenComparing(g -> g.key().category()));
        return groups.stream()
                .map(g -> new PermissionCatalogDto(g.key().module(), g.key().category(), g.items()))
                .toList();
    }

    /** 某部门已直配的权限点 code 列表。 */
    @Transactional(readOnly = true)
    public DepartmentPermissionsDto getDepartmentPermissions(UUID departmentId) {
        support.requireCurrentSuperAdmin();
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
     * <p>权限点可直接控制所有业务端点，因此必须经过独立的超级管理员守卫。
     */
    @Transactional
    public void setDepartmentPermissions(UUID departmentId, List<String> permissionCodes) {
        support.requireCurrentSuperAdmin();
        tx.bind();
        requireDepartment(departmentId);
        // 去重（保持顺序），避免主键冲突
        Set<String> codes = new LinkedHashSet<>(permissionCodes == null ? List.of() : permissionCodes);
        if (codes.stream().anyMatch(INDIVIDUAL_ONLY_PERMISSION_CODES::contains)) {
            throw new ApiException(ErrorCode.BUSINESS, "审计权限仅允许个人授权");
        }
        Map<String, Permission> byCode = permissionRepo.findByCodeIn(codes).stream()
                .collect(Collectors.toMap(Permission::getCode, p -> p));
        for (String code : codes) {
            Permission permission = byCode.get(code);
            if (permission == null) {
                throw new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code);
            }
            requireAssignable(permission);
        }
        UUID actor = currentUser.id().orElse(null);
        departmentPermissionRepo.deleteByIdDepartmentId(departmentId);
        for (String code : codes) {
            DepartmentPermission dp = new DepartmentPermission();
            dp.setId(new DepartmentPermissionId(departmentId, byCode.get(code).getId()));
            dp.setCreatedBy(actor);
            departmentPermissionRepo.save(dp);
        }
        // 吊销该部门子树（含下级部门）所有用户的 refresh token，阻止旧权限继续续期。
        // 已签发 access token 的权限快照仍持续到其 exp；上线前需通过权限版本校验
        // 或更短 TTL 进一步收口权限回收窗口。
        for (UUID uid : employeeRepo.findUserIdsByDepartmentSubtree(departmentId)) {
            refreshTokenRepo.revokeAllByUserId(uid);
        }
    }

    /** 某用户的有效权限分解（复用 PermissionResolver 的合成逻辑，单一事实来源）。 */
    @Transactional(readOnly = true)
    public EffectivePermissionsDto effectivePermissions(UUID userId) {
        support.requireCurrentSuperAdmin();
        UserAccount target = support.require(userId);
        PermissionResolver.PermBreakdown b = permissionResolver.breakdownOf(target);
        return new EffectivePermissionsDto(
                b.departmentId(),
                b.departmentName(),
                b.departmentPermissions().stream().sorted().toList(),
                b.baselinePermissions().stream().sorted().toList(),
                b.grants().stream().sorted().toList(),
                b.confirmedGrants().stream().sorted().toList(),
                b.legacyUnknownGrants().stream().sorted().toList(),
                b.legacyUnknownRevokes().stream().sorted().toList(),
                b.managerGrants().stream().sorted().toList(),
                b.revokes().stream().sorted().toList(),
                b.effective().stream().sorted().toList(),
                target.isSuperAdmin());
    }

    private void requireDepartment(UUID departmentId) {
        departmentRepo.findById(departmentId).filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
    }

    private void requireAssignable(Permission permission) {
        if (!permission.isActive() || !permission.isAssignable()) {
            throw new ApiException(
                    ErrorCode.BUSINESS,
                    "权限已停用或不可再分配: " + permission.getCode());
        }
    }

    private String normalizedActionType(String value) {
        return value == null || value.isBlank() ? "OTHER" : value;
    }
}
