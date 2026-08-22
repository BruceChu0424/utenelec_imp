package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentLevelPolicy;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Comparator;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Single organization-management scope authority for contextual delegation.
 *
 * <p>The only organization authority sources are an active super-admin account
 * and the existing {@code departments.manager_id} relationship. Position
 * names, employee supervisor links and retired explicit appointments never
 * participate in authorization.</p>
 */
@Service
public class OrganizationPermissionManagementScopeService {

    private static final Set<String> CURRENT_EMPLOYEE_STATUSES =
            Set.of("active", "probation", "onLeave");

    public enum AuthoritySource {
        SUPER_ADMIN,
        DEPARTMENT_MANAGER
    }

    public enum AuthorityScope {
        COMPANY,
        SUBTREE
    }

    public enum StaffSearchScope {
        SUPER_ADMIN_COMPANY,
        EXECUTIVE_OFFICE_COMPANY,
        MANAGER_SUBTREES
    }

    public record StaffSearchAuthority(
            StaffSearchScope scope,
            UUID managerEmployeeId) {
    }

    public record ManagementAuthority(
            AuthoritySource source,
            UUID id,
            long version,
            UUID rootDepartmentId,
            Long rootGeneration,
            AuthorityScope scopeType) {
    }

    public record ManagedDepartmentAuthority(
            UUID departmentId,
            String code,
            String departmentName,
            String level,
            UUID parentId,
            Integer sortOrder,
            boolean selectable,
            ManagementAuthority authority) {
    }

    private final EmployeeRepository employeeRepo;
    private final UserAccountRepository userAccountRepo;
    private final DepartmentRepository departmentRepo;

    public OrganizationPermissionManagementScopeService(
            EmployeeRepository employeeRepo,
            UserAccountRepository userAccountRepo,
            DepartmentRepository departmentRepo) {
        this.employeeRepo = employeeRepo;
        this.userAccountRepo = userAccountRepo;
        this.departmentRepo = departmentRepo;
    }

    /**
     * Cheap capability probe that never materializes the managed organization
     * tree. The full account and employee checks remain fail-closed.
     */
    @Transactional(readOnly = true)
    public boolean hasManagementAuthority(AuthUser actor) {
        Optional<ActorContext> context = actorContext(actor);
        if (context.isEmpty()) {
            return false;
        }
        if (context.get().superAdmin()) {
            return true;
        }
        return departmentRepo.existsManageableDepartmentByManagerId(
                context.get().employee().getId());
    }

    @Transactional(readOnly = true)
    public Optional<StaffSearchAuthority> staffSearchAuthority(AuthUser actor) {
        Optional<ActorContext> context = actorContext(actor);
        if (context.isEmpty()) {
            return Optional.empty();
        }
        if (context.get().superAdmin()) {
            return Optional.of(new StaffSearchAuthority(
                    StaffSearchScope.SUPER_ADMIN_COMPANY,
                    null));
        }
        List<Department> roots = authorizedManagerRoots(context.get());
        if (roots.isEmpty()) {
            return Optional.empty();
        }
        if (companyExecutiveOfficeRoot(context.get(), roots).isPresent()) {
            return Optional.of(new StaffSearchAuthority(
                    StaffSearchScope.EXECUTIVE_OFFICE_COMPANY,
                    context.get().employee().getId()));
        }
        return Optional.of(new StaffSearchAuthority(
                StaffSearchScope.MANAGER_SUBTREES,
                context.get().employee().getId()));
    }

    @Transactional(readOnly = true)
    public List<ManagedDepartmentAuthority> managedDepartments(AuthUser actor) {
        Optional<ActorContext> context = actorContext(actor);
        if (context.isEmpty()) {
            return List.of();
        }
        if (context.get().superAdmin()) {
            ManagementAuthority authority = superAdminCompanyAuthority(
                    context.get());
            return departmentRepo.findByDeletedFalseOrderBySortOrderAscNameAsc()
                    .stream()
                    .map(department -> managedDepartment(department, authority))
                    .toList();
        }

        List<Department> roots = authorizedManagerRoots(context.get());
        if (roots.isEmpty()) {
            return List.of();
        }
        Optional<Department> companyOffice = companyExecutiveOfficeRoot(
                context.get(), roots);
        if (companyOffice.isPresent()) {
            ManagementAuthority authority = companyManagerAuthority(
                    companyOffice.orElseThrow());
            return departmentRepo.findByDeletedFalseOrderBySortOrderAscNameAsc()
                    .stream()
                    .map(department -> managedDepartment(department, authority))
                    .toList();
        }
        UUID employeeId = context.get().employee().getId();
        return departmentRepo.findManagedDepartments(employeeId).stream()
                .filter(department -> !department.isDeleted())
                .map(department -> managedDepartmentForManager(
                        department,
                        roots))
                .flatMap(Optional::stream)
                .toList();
    }

    @Transactional(readOnly = true)
    public Optional<ManagementAuthority> resolveAuthority(
            AuthUser actor,
            UUID targetDepartmentId) {
        if (targetDepartmentId == null) {
            return Optional.empty();
        }
        Optional<ActorContext> context = actorContext(actor);
        if (context.isEmpty()) {
            return Optional.empty();
        }
        Department target = departmentRepo.findById(targetDepartmentId)
                .filter(this::isManageableDepartment)
                .orElse(null);
        if (target == null) {
            return Optional.empty();
        }
        if (context.get().superAdmin()) {
            return Optional.of(superAdminCompanyAuthority(
                    context.get()));
        }

        UUID employeeId = context.get().employee().getId();
        UUID rootId = departmentRepo.findManagerScopeDepartmentId(
                        targetDepartmentId,
                        employeeId)
                .orElse(null);
        if (rootId == null) {
            return Optional.empty();
        }
        Department root = rootId.equals(targetDepartmentId)
                ? target
                : departmentRepo.findById(rootId)
                        .filter(this::isManageableDepartment)
                        .orElse(null);
        if (!isAuthorizedManagerRoot(context.get(), root)) {
            return Optional.empty();
        }
        if (DepartmentLevelPolicy.isCompanyExecutiveOffice(root)) {
            return Optional.of(companyManagerAuthority(root));
        }
        return Optional.of(departmentManagerAuthority(root));
    }

    private Optional<ActorContext> actorContext(AuthUser actor) {
        if (actor == null || actor.isVisitor()) {
            return Optional.empty();
        }
        UserAccount account = userAccountRepo.findById(actor.getId())
                .filter(row -> !row.isDeleted() && "active".equals(row.getStatus()))
                .orElse(null);
        if (account == null || actor.isSuperAdmin() != account.isSuperAdmin()) {
            return Optional.empty();
        }
        if (account.isSuperAdmin()) {
            return Optional.of(new ActorContext(actor, account, null, true));
        }
        if (actor.getEmployeeId() == null
                || !actor.getEmployeeId().equals(account.getEmployeeId())) {
            return Optional.empty();
        }
        Employee employee = employeeRepo.findById(actor.getEmployeeId())
                .orElse(null);
        if (!isCurrentEmployee(employee)) {
            return Optional.empty();
        }
        return Optional.of(new ActorContext(actor, account, employee, false));
    }

    private List<Department> authorizedManagerRoots(ActorContext context) {
        return departmentRepo.findByManagerId(context.employee().getId())
                .stream()
                .filter(root -> isAuthorizedManagerRoot(context, root))
                .toList();
    }

    private boolean isAuthorizedManagerRoot(
            ActorContext context,
            Department root) {
        if (!isManageableDepartment(root)
                || root.getManager() == null
                || !root.getManager().getId().equals(context.employee().getId())) {
            return false;
        }
        if (DepartmentLevelPolicy.isCompanyExecutiveOfficeCode(root.getCode())) {
            return isCompanyExecutiveOfficeManager(context, root);
        }
        return true;
    }

    private Optional<Department> companyExecutiveOfficeRoot(
            ActorContext context,
            List<Department> roots) {
        return roots.stream()
                .filter(root -> isCompanyExecutiveOfficeManager(context, root))
                .findFirst();
    }

    private boolean isCompanyExecutiveOfficeManager(
            ActorContext context,
            Department root) {
        Employee employee = context.employee();
        return employee != null
                && employee.getDepartment() != null
                && employee.getDepartment().getId().equals(root.getId())
                && root.getManager() != null
                && root.getManager().getId().equals(employee.getId())
                && DepartmentLevelPolicy.isCompanyExecutiveOffice(root);
    }

    private Optional<ManagedDepartmentAuthority> managedDepartmentForManager(
            Department department,
            List<Department> roots) {
        Department root = roots.stream()
                .filter(candidate -> candidate.getId().equals(department.getId()))
                .findFirst()
                .orElseGet(() -> roots.stream()
                        .filter(candidate -> isWithinPath(candidate, department))
                        .max(Comparator.comparingInt(candidate ->
                                candidate.getPath().length()))
                        .orElse(null));
        if (root == null) {
            return Optional.empty();
        }
        return Optional.of(managedDepartment(
                department,
                departmentManagerAuthority(root)));
    }

    private boolean isWithinPath(Department root, Department target) {
        return root.getPath() != null
                && target.getPath() != null
                && target.getPath().startsWith(root.getPath());
    }

    private ManagedDepartmentAuthority managedDepartment(
            Department department,
            ManagementAuthority authority) {
        return new ManagedDepartmentAuthority(
                department.getId(),
                department.getCode(),
                department.getName(),
                department.getLevel(),
                department.getParent() == null
                        ? null : department.getParent().getId(),
                department.getSortOrder(),
                DepartmentLevelPolicy.canHostEmployees(department.getLevel()),
                authority);
    }

    private ManagementAuthority superAdminCompanyAuthority(
            ActorContext context) {
        return new ManagementAuthority(
                AuthoritySource.SUPER_ADMIN,
                context.actor().getId(),
                context.account().getPermissionDelegationGeneration(),
                null,
                null,
                AuthorityScope.COMPANY);
    }

    private ManagementAuthority companyManagerAuthority(Department root) {
        return new ManagementAuthority(
                AuthoritySource.DEPARTMENT_MANAGER,
                root.getId(),
                root.getPermissionDelegationGeneration(),
                root.getId(),
                root.getPermissionDelegationGeneration(),
                AuthorityScope.COMPANY);
    }

    private ManagementAuthority departmentManagerAuthority(Department root) {
        return new ManagementAuthority(
                AuthoritySource.DEPARTMENT_MANAGER,
                root.getId(),
                root.getPermissionDelegationGeneration(),
                root.getId(),
                root.getPermissionDelegationGeneration(),
                AuthorityScope.SUBTREE);
    }

    private boolean isManageableDepartment(Department department) {
        return department != null
                && !department.isDeleted()
                && DepartmentLevelPolicy.canHostEmployees(department.getLevel());
    }

    private boolean isCurrentEmployee(Employee employee) {
        return employee != null
                && !employee.isDeleted()
                && CURRENT_EMPLOYEE_STATUSES.contains(employee.getStatus());
    }

    private record ActorContext(
            AuthUser actor,
            UserAccount account,
            Employee employee,
            boolean superAdmin) {
    }
}
