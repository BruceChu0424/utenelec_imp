package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.DepartmentPermissionsDto;
import com.uten.imp.features.admin.dto.EffectivePermissionsDto;
import com.uten.imp.features.admin.dto.PermissionBulkScopeDto;
import com.uten.imp.features.admin.dto.PermissionCatalogDto;
import com.uten.imp.features.admin.dto.PermissionChangeDto;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.GrantPolicy;
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
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 权限目录 / 部门直配权限点 / 全员基础包 / 用户有效权限分解(管理端)。
 * 授权策略仅允许超级管理员维护；权限点本身就是安全边界。
 *
 * <p>ADR-109：「能怎么授」只读 permissions.grant_policy。保存一律按差量处理——只校验本次
 * 新增能否授予，不可再授但已经存在的保留不动，收回一律允许；真的有改动才写库并记一条
 * 带 added/removed 的业务事件，没有改动时 0 行写入、0 行审计。
 */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class DepartmentPermissionAdminService {

    /**
     * 一级模块的固定显示顺序。未列出的模块（如兜底「其他」）排在最后并按名字稳定排序，
     * 保证权限目录始终以业务主干顺序呈现、新增模块不会随机穿插。
     */
    private static final List<String> MODULE_ORDER = List.of(
            "基础资料", "销售管理", "采购管理", "委外管理", "生产管理",
            "仓库管理", "财税管理", "工程研发", "人事行政", "品质检测", "系统管理",
            // V546：跨模块共用的附件权限（attachment:*）归「通用 → 附件」，排在业务模块之后。
            "通用");

    private final PermissionRepository permissionRepo;
    private final DepartmentRepository departmentRepo;
    private final DepartmentPermissionRepository departmentPermissionRepo;
    private final PermissionResolver permissionResolver;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final AdminUserSupport support;
    private final EmployeeRepository employeeRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final PermissionChangeAudit changeAudit;

    /**
     * 完整权限目录（两级：module → category → 权限项）。
     * 按 (module, category) 分组；module 为空归「其他」。组内权限按 sort_order → code 升序；
     * 组间按「模块在 {@link #MODULE_ORDER} 中的序号（未列出者排最后）→ 组内最小 sort_order → 子类名」稳定排序。
     */
    @Transactional(readOnly = true)
    public List<PermissionCatalogDto> catalog() {
        support.requireCurrentSuperAdmin();
        record GroupKey(String module, String category) {}
        Map<GroupKey, List<Permission>> byGroup = permissionRepo.findAll().stream()
                .collect(Collectors.groupingBy(
                        p -> new GroupKey(moduleOf(p), p.getCategory() == null ? "" : p.getCategory()),
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
                            p.grantPolicies().stream().map(Enum::name).toList(),
                            p.isBaseline(),
                            p.getSensitivity())).toList()));
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
     * 保存某部门的直配权限点(请求体是期望的完整集合，服务端按差量落库)。
     *
     * <p>未知 code 报错拒绝(前端传错 code 属于调用方 bug，应尽早暴露)；只对本次新增的码
     * 校验能否配置给部门(INDIVIDUAL_ONLY / SUPERADMIN_ONLY 拒绝)，历史上已存在的码
     * 原样保留、收回一律允许。
     */
    @Transactional
    public PermissionChangeDto setDepartmentPermissions(UUID departmentId, List<String> permissionCodes) {
        support.requireCurrentSuperAdmin();
        tx.bind();
        lockDepartment(departmentId);
        Set<String> desired = new LinkedHashSet<>(permissionCodes == null ? List.of() : permissionCodes);
        Set<String> current = new HashSet<>(
                departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId));
        Set<String> added = new LinkedHashSet<>(desired);
        added.removeAll(current);
        Set<String> removed = new LinkedHashSet<>(current);
        removed.removeAll(desired);
        Set<String> touched = new LinkedHashSet<>(added);
        touched.addAll(removed);
        Map<String, Permission> byCode = byCode(touched);
        for (String code : added) {
            Permission permission = byCode.get(code);
            if (permission == null) {
                throw new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code);
            }
            Set<GrantPolicy> policy = permission.grantPolicies();
            if (!GrantPolicy.departmentGrantable(policy)) {
                throw new ApiException(ErrorCode.BUSINESS,
                        GrantPolicy.departmentRefusal(policy) + "：" + permission.getName());
            }
        }
        return applyDepartmentChange(departmentId, added, removed, byCode);
    }

    /**
     * 「全部授权 / 本模块 / 本组」：服务端按 grant_policy 挑出可批量且可配给部门的码，
     * 只补本部门还没有的；BULK_EXCLUDED / INDIVIDUAL_ONLY / SUPERADMIN_ONLY 一律不带上。
     */
    @Transactional
    public PermissionChangeDto grantAll(UUID departmentId, PermissionBulkScopeDto scope) {
        support.requireCurrentSuperAdmin();
        tx.bind();
        lockDepartment(departmentId);
        Set<String> current = new HashSet<>(
                departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId));
        Map<String, Permission> byCode = new LinkedHashMap<>();
        Set<String> added = new LinkedHashSet<>();
        for (Permission permission : bulkCandidates(scope)) {
            Set<GrantPolicy> policy = permission.grantPolicies();
            if (GrantPolicy.departmentGrantable(policy) && !current.contains(permission.getCode())) {
                added.add(permission.getCode());
                byCode.put(permission.getCode(), permission);
            }
        }
        return applyDepartmentChange(departmentId, added, Set.of(), byCode);
    }

    /** 全员基础包(每个在职员工都隐式持有的码)。 */
    @Transactional(readOnly = true)
    public DepartmentPermissionsDto baseline() {
        support.requireCurrentSuperAdmin();
        return new DepartmentPermissionsDto(permissionRepo.findBaselineCodes().stream().sorted().toList());
    }

    /**
     * 保存全员基础包(期望的完整集合，服务端按差量落库)。只校验本次新增的码能否进基础包
     * (不可批量 / 个人专属 / 超管专属的码不行)；移出一律允许。改动经 permissions 表的
     * 授权纪元触发器让全员旧令牌失效，下次续期即按新基础包合成。
     */
    @Transactional
    public PermissionChangeDto setBaseline(List<String> permissionCodes) {
        support.requireCurrentSuperAdmin();
        tx.bind();
        Set<String> desired = new LinkedHashSet<>(permissionCodes == null ? List.of() : permissionCodes);
        // 两个超管同时改基础包时串行化，先到者提交后后到者再读，差量与审计不会重复或丢失。
        permissionRepo.lockBaseline();
        Set<String> current = new HashSet<>(permissionRepo.findBaselineCodes());
        Set<String> added = new LinkedHashSet<>(desired);
        added.removeAll(current);
        Set<String> removed = new LinkedHashSet<>(current);
        removed.removeAll(desired);
        if (added.isEmpty() && removed.isEmpty()) {
            return PermissionChangeDto.unchanged();
        }
        Map<String, Permission> byCode = byCode(added);
        for (String code : added) {
            Permission permission = byCode.get(code);
            if (permission == null) {
                throw new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code);
            }
            if (!GrantPolicy.baselineEligible(permission.grantPolicies())) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "这项权限不能发给全员(敏感、个人专属或超管专属)：" + permission.getName());
            }
        }
        UUID actor = currentUser.id().orElse(null);
        if (!added.isEmpty()) {
            permissionRepo.updateBaseline(added, true, actor);
        }
        if (!removed.isEmpty()) {
            permissionRepo.updateBaseline(removed, false, actor);
        }
        changeAudit.record("permission_baseline_change", "permissions", "baseline",
                added, removed, null);
        return new PermissionChangeDto(sorted(added), sorted(removed));
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

    /** 批量授权候选：目录里可批量的码按范围筛选(范围字段为空 = 不限)。 */
    List<Permission> bulkCandidates(PermissionBulkScopeDto scope) {
        PermissionBulkScopeDto range = scope == null ? PermissionBulkScopeDto.everything() : scope;
        String module = blankToNull(range.module());
        String category = range.category();
        return permissionRepo.findAll().stream()
                .filter(p -> GrantPolicy.bulkEligible(p.grantPolicies()))
                .filter(p -> module == null || module.equals(moduleOf(p)))
                .filter(p -> category == null || category.equals(p.getCategory() == null ? "" : p.getCategory()))
                .sorted(Comparator.comparing(Permission::getCode))
                .toList();
    }

    private PermissionChangeDto applyDepartmentChange(
            UUID departmentId, Set<String> added, Set<String> removed, Map<String, Permission> byCode) {
        if (added.isEmpty() && removed.isEmpty()) {
            return PermissionChangeDto.unchanged();
        }
        // 部门行已锁：实际写入行数必须等于算出的差量，否则说明有绕过本服务的写入，
        // 拒绝保存而不是记一条与实际不符的审计。
        int inserted = added.isEmpty() ? 0
                : departmentPermissionRepo.insertGrants(departmentId, added, currentUser.id().orElse(null));
        int deleted = removed.isEmpty() ? 0
                : departmentPermissionRepo.deleteGrants(departmentId, removed.stream()
                        .map(byCode::get)
                        .filter(Objects::nonNull)
                        .map(Permission::getId)
                        .toList());
        if (inserted != added.size() || deleted != removed.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "这个部门的权限刚被改过，请刷新后再保存");
        }
        // 吊销该部门子树(含下级部门)所有用户的 refresh token；已签发的 access token 由
        // department_permissions 的授权纪元触发器统一失效，下一次续期按新配置合成。
        for (UUID uid : employeeRepo.findUserIdsByDepartmentSubtree(departmentId)) {
            refreshTokenRepo.revokeAllByUserId(uid);
        }
        changeAudit.record("department_permission_change", "departments", departmentId.toString(),
                added, removed, null);
        return new PermissionChangeDto(sorted(added), sorted(removed));
    }

    private Map<String, Permission> byCode(Set<String> codes) {
        if (codes.isEmpty()) {
            return Map.of();
        }
        return permissionRepo.findByCodeIn(codes).stream()
                .collect(Collectors.toMap(Permission::getCode, p -> p));
    }

    private void lockDepartment(UUID departmentId) {
        if (departmentPermissionRepo.lockLiveDepartment(departmentId).isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "部门不存在");
        }
    }

    private void requireDepartment(UUID departmentId) {
        departmentRepo.findById(departmentId).filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
    }

    private static String moduleOf(Permission permission) {
        return permission.getModule() == null || permission.getModule().isBlank()
                ? "其他" : permission.getModule();
    }

    private static List<String> sorted(Set<String> codes) {
        return codes.stream().sorted().toList();
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }

    private String normalizedActionType(String value) {
        return value == null || value.isBlank() ? "OTHER" : value;
    }
}
