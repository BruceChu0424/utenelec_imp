package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.staffpermission.dto.DepartmentStaffPermissionsDto;
import com.uten.imp.features.org.department.staffpermission.dto.DepartmentStaffPermissionsDto.PermissionItem;
import com.uten.imp.features.org.department.staffpermission.dto.DepartmentStaffPermissionsDto.StaffRow;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverride;
import com.uten.imp.features.rbac.UserPermissionOverrideId;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 部门主管管理"本部门员工权限"（问题 #20）。
 *
 * <p>与 {@code PermissionOverrideAdminService}（超管专用、可授予目录内任意权限点）不同：
 * 这里的授权人不是超管，而是普通员工里被标记为"本部门负责人"的那一个
 * （department.manager_id == 当前登录人 employee.id，见 EmployeeQueryService.leaderRank）。
 * 因此这里的每个入口都要在方法体内做数据驱动的越权校验，不能只靠 @PreAuthorize 的静态权限点：
 * <ol>
 *   <li>调用者必须确实是自己所在部门的 manager_id；</li>
 *   <li>操作对象必须是同一部门（不含子部门——子部门有自己的主管）的在册员工；</li>
 *   <li>能转授的权限点上限 = 负责人本人有效权限 ∖ 全员基础权限（只转授自己持有的、且非人人皆有的权限）：
 *       既可对本部门配置权限（默认全员开）做开/关，也可把自己额外持有的权限授予成员；不能凭空升级。</li>
 * </ol>
 */
@Service
@RequiredArgsConstructor
public class DepartmentStaffPermissionService {

    private final EmployeeRepository employeeRepo;
    private final UserAccountRepository userAccountRepo;
    private final DepartmentPermissionRepository departmentPermissionRepo;
    private final PermissionRepository permissionRepo;
    private final UserPermissionOverrideRepository overrideRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final PermissionResolver permissionResolver;

    private static final Set<String> ALLOWED_EFFECTS = Set.of("grant", "revoke");

    /** 当前登录人管理的部门；不是任何部门的 manager_id 时 403。 */
    @Transactional(readOnly = true)
    Department requireManagedDepartment() {
        UUID employeeId = currentUser.requireEmployeeId();
        Employee me = employeeRepo.findById(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "当前账号未绑定有效员工档案"));
        Department dept = me.getDepartment();
        if (dept == null || dept.getManager() == null || !dept.getManager().getId().equals(employeeId)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅本部门负责人可管理部门员工权限");
        }
        return dept;
    }

    /** 负责人可转授的权限点上限 = 本人有效权限 ∖ 全员基础权限（不转授人人皆有的基础权限）。 */
    private Set<String> headCeilingCodes() {
        UserAccount head = userAccountRepo.findById(currentUser.requireId())
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "当前账号无效"));
        PermissionResolver.PermBreakdown breakdown = permissionResolver.breakdownOf(head);
        Set<String> ceiling = new HashSet<>(breakdown.effective());
        ceiling.removeAll(breakdown.baselinePermissions());
        return ceiling;
    }

    @Transactional(readOnly = true)
    public DepartmentStaffPermissionsDto getManagedStaffPermissions() {
        Department dept = requireManagedDepartment();
        Set<String> ceilingCodes = headCeilingCodes();
        Set<String> deptBaselineCodes = new HashSet<>(
                departmentPermissionRepo.findPermissionCodesByDepartmentIdWithAncestors(dept.getId()));

        List<Employee> staff =
                employeeRepo.findByDepartmentIdAndDeletedFalseOrderByFullNameAsc(dept.getId());
        // 预读每个员工的个人覆盖；同时收集"孤儿"code（负责人此前授予、现已不再持有、但成员仍持有的覆盖点），
        // 让面板能展示并允许负责人收回，避免权限维护盲区。
        record StaffOverride(UserAccount account, Map<String, String> overrides) {}
        List<StaffOverride> loaded = new ArrayList<>(staff.size());
        Set<String> overrideCodes = new HashSet<>();
        for (Employee e : staff) {
            UserAccount account = userAccountRepo.findByEmployeeId(e.getId()).orElse(null);
            Map<String, String> overrides = new LinkedHashMap<>();
            if (account != null) {
                for (Object[] row : overrideRepo.findCodeAndEffectByUserId(account.getId())) {
                    String c = (String) row[0];
                    overrides.put(c, (String) row[1]);
                    overrideCodes.add(c);
                }
            }
            loaded.add(new StaffOverride(account, overrides));
        }

        // 可展示权限点 = 负责人 ceiling ∪ 成员现存覆盖点。
        Set<String> allCodes = new HashSet<>(ceilingCodes);
        allCodes.addAll(overrideCodes);
        List<Permission> permissions = allCodes.isEmpty()
                ? List.of() : permissionRepo.findByCodeIn(allCodes);
        permissions.sort(Comparator.comparing(Permission::getCode));
        List<PermissionItem> permissionItems = permissions.stream()
                .map(p -> new PermissionItem(p.getCode(), p.getName(), deptBaselineCodes.contains(p.getCode())))
                .toList();
        Map<String, UUID> permissionIdByCode = new HashMap<>();
        for (Permission p : permissions) permissionIdByCode.put(p.getCode(), p.getId());

        UUID managerId = dept.getManager() == null ? null : dept.getManager().getId();
        List<StaffRow> rows = new ArrayList<>(staff.size());
        for (int i = 0; i < staff.size(); i++) {
            Employee e = staff.get(i);
            StaffOverride so = loaded.get(i);
            Map<String, String> overrides = new LinkedHashMap<>();
            if (so.account() != null) {
                for (Map.Entry<String, String> en : so.overrides().entrySet()) {
                    if (permissionIdByCode.containsKey(en.getKey())) {
                        overrides.put(en.getKey(), en.getValue());
                    }
                }
            }
            rows.add(new StaffRow(
                    e.getId(),
                    e.getCode(),
                    e.getFullName(),
                    e.getPosition() == null ? null : e.getPosition().getName(),
                    e.getId().equals(managerId),
                    so.account() != null,
                    overrides));
        }

        return new DepartmentStaffPermissionsDto(dept.getId(), dept.getName(), permissionItems, rows);
    }

    /**
     * 设置/清除某员工单个权限点的个人覆盖。effect 为 null 清除（回落基线）；否则必须是 grant/revoke。
     * <p>授权(grant)须在本人可转授上限内；收回(revoke/清除)对成员现存的覆盖点始终允许
     * （即便负责人已不再持有该权限点，也能收回此前授予的覆盖，避免孤儿覆盖残留）。
     * 不允许负责人修改本人的覆盖（防自锁）。
     */
    @Transactional
    public void setStaffOverride(UUID employeeId, String code, String effect) {
        tx.bind();
        Department dept = requireManagedDepartment();

        if (effect != null && !ALLOWED_EFFECTS.contains(effect)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法覆盖方向: " + effect);
        }

        Employee target = employeeRepo.findById(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工不存在"));
        if (target.getDepartment() == null || !target.getDepartment().getId().equals(dept.getId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能管理本部门员工的权限");
        }
        if (target.getId().equals(currentUser.requireEmployeeId())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不能修改本人的权限覆盖");
        }

        Permission permission = permissionRepo.findByCode(code)
                .orElseThrow(() -> new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code));
        UserAccount account = userAccountRepo.findByEmployeeId(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.BUSINESS, "该员工尚未开通登录账号，暂无法授权"));

        boolean revokeOp = effect == null || "revoke".equals(effect);
        boolean inCeiling = headCeilingCodes().contains(code);
        boolean targetHasOverride = false;
        for (Object[] row : overrideRepo.findCodeAndEffectByUserId(account.getId())) {
            if (code.equals(row[0])) {
                targetHasOverride = true;
                break;
            }
        }
        // grant 须在 ceiling 内；revoke/清除对现存覆盖点始终允许（含负责人已不再持有的孤儿覆盖）。
        if (!inCeiling && !(revokeOp && targetHasOverride)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "该权限点不在你可转授的范围内: " + code);
        }

        UserPermissionOverrideId id = new UserPermissionOverrideId(account.getId(), permission.getId());
        if (effect == null) {
            overrideRepo.deleteById(id);
        } else {
            UserPermissionOverride o = new UserPermissionOverride();
            o.setId(id);
            o.setEffect(effect);
            overrideRepo.save(o);
        }
        // 立即生效：吊销该员工的 refresh token，阻止旧权限继续续期
        // （同 PermissionOverrideAdminService.setPermissionOverrides 的收尾方式）。
        refreshTokenRepo.revokeAllByUserId(account.getId());
    }
}
