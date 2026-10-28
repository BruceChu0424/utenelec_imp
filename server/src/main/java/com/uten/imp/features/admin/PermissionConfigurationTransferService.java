package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionTransferDtos.*;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import java.util.function.Function;
import java.util.stream.Collectors;

/** Portable configuration is input, never authority. Every import is a new, reviewed authorization decision. */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class PermissionConfigurationTransferService {
    public static final String FORMAT = "uten.permission-configuration";
    private static final List<String> NOTES = List.of(
            "保留备份中有效的个人加授与收回，再补齐目标继承差异和有效委派；由本次超级管理员确认，不伪造原委派关系。停用或历史覆盖仅供审阅，不重新激活。",
            "不修改账号密码、超级管理员身份、远程访问资格、员工部门或岗位。未选中的部门和账号保持原配置。",
            "编号相同只提供匹配建议，请核对目标部门、员工和数据范围归属人后确认。",
            "操作权限相同不代表业务数据归属或审批职责相同；数据范围仅在明确选择恢复时修改。",
            "基础包或部门权限变更会使现有负责人委派失效；个人策略变更也会影响该账号授给别人的委派。间接影响会另列，请核对接收员工，必要时重新委派。");
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final AdminUserSupport support;
    private final UserAccountRepository accounts;
    private final PermissionRepository permissions;
    private final DepartmentPermissionRepository departmentGrants;
    private final PermissionResolver resolver;
    private final DepartmentPermissionAdminService departmentAdmin;
    private final PermissionOverrideAdminService overrideAdmin;
    private final DataScopeAdminService scopeAdmin;
    private final DataScopeCatalogService scopeCatalog;
    private final PermissionChangeAudit audit;
    private final PermissionTemplateBindingService templateBindings;
    private final TxSessionVars tx;

    @Transactional(readOnly=true, isolation=Isolation.REPEATABLE_READ)
    public Backup exportConfiguration() {
        requireActor();
        List<DepartmentConfiguration> departments = rows("SELECT id,code,name FROM departments WHERE NOT is_deleted ORDER BY code,id")
                .stream().map(row -> new DepartmentConfiguration(row[0].toString(), string(row[1]), string(row[2]),
                        sorted(departmentConfigurationCodes((UUID) row[0])))).toList();
        List<UserConfiguration> users = new ArrayList<>();
        Map<String, ScopeOwner> owners = new TreeMap<>();
        for (Object[] row : rows("""
                SELECT u.id,e.code,e.full_name,u.login_account,u.status,e.status,e.is_deleted FROM users u JOIN employees e ON e.id=u.employee_id
                WHERE NOT u.is_deleted AND NOT u.is_super_admin ORDER BY e.code,u.id
                """)) {
            UserAccount user = support.require((UUID) row[0]);
            var breakdown = resolver.breakdownOf(user);
            Map<String,List<String>> scopes = new TreeMap<>();
            for (String scope : scopeCodes()) {
                List<String> ids = new ArrayList<>();
                for (UUID id : scopeAdmin.getDataScopes(user.getId(), scope)) {
                    Object[] owner = first(rowsById("SELECT id,code,full_name,status FROM employees WHERE id=:id",id));
                    if (owner == null) throw conflict("数据范围归属人不存在，请先修复配置再导出");
                    owners.put(id.toString(), new ScopeOwner(id.toString(), string(owner[1]), string(owner[2])));
                    ids.add(id.toString());
                }
                scopes.put(scope, sorted(ids));
            }
            boolean current=!Boolean.TRUE.equals(row[6]) && CurrentEmployeeStatusPolicy.isCurrentEmployee(string(row[5]));
            boolean restorable=current && Set.of("active","locked").contains(string(row[4]));
            String reason=!current ? "员工已离职或档案已删除，仅保留配置供审阅，不自动恢复"
                    : "disabled".equals(row[4]) ? "账号已停用，仅保留配置供审阅，不自动恢复"
                    : "locked".equals(row[4]) ? "账号临时锁定，权限配置仍完整保留；可恢复到已启用的目标账号" : "";
            users.add(new UserConfiguration(user.getId().toString(), string(row[1]), string(row[2]), string(row[3]),
                    sorted(breakdown.grants()), sorted(breakdown.revokes()), sorted(breakdown.effective()),
                    sorted(breakdown.managerGrants()), scopes,string(row[4]),string(row[5]),restorable,reason,storedOverrides(user.getId())));
        }
        Backup backup = new Backup(FORMAT,1,Instant.now().toString(),sorted(permissions.findBaselineCodes()),
                departments,List.copyOf(users),List.copyOf(owners.values()));
        validateBackup(backup);
        return backup;
    }

    @Transactional(readOnly=true, isolation=Isolation.REPEATABLE_READ)
    public Preview previewImport(ImportRequest request) {
        requireActor();
        return importPlan(request).preview();
    }

    @Transactional
    public Result importConfiguration(ImportCommit commit) {
        lockExistingEntryPoints(commit.request());
        lockConfiguration();
        requireActor();
        Plan plan = importPlan(commit.request());
        confirm(plan.preview(),commit.expectedFingerprint(),commit.sensitiveConfirmations());
        tx.bind();
        boolean changed=templateBindings.list().stream().anyMatch(binding->binding.kind().equals("user")
                ? plan.users.containsKey(binding.targetId()):plan.departments.containsKey(binding.targetId()));
        if (plan.baseline != null) changed=!departmentAdmin.restoreExactBaseline(sorted(plan.baseline)).isEmpty() || changed;
        templateBindings.clearForDepartments(plan.departments.keySet());
        templateBindings.clearForUsers(plan.users.keySet());
        for (var item : plan.departments.entrySet()) changed=!departmentAdmin.restoreExactDepartmentPermissions(item.getKey(),sorted(item.getValue())).isEmpty() || changed;
        // Department/baseline changes may invalidate contextual delegations; resolve after those writes.
        em.flush(); em.clear();
        for (var item : plan.users.entrySet()) {
            OverrideConfiguration raw=plan.overrides.get(item.getKey());
            changed=!overrideAdmin.restoreExactPermissionOverrides(item.getKey(),raw.grants(),raw.revokes(),item.getValue()).isEmpty() || changed;
        }
        for (var user : plan.scopes.entrySet()) for (var scope : user.getValue().entrySet()) {
            var current=scopeAdmin.getDataScopes(user.getKey(),scope.getKey());
            changed=!new HashSet<>(current).equals(new HashSet<>(scope.getValue())) || changed;
            scopeAdmin.setDataScopes(user.getKey(),scope.getKey(),scope.getValue(),current);
        }
        em.flush(); em.clear();
        for (var item : plan.users.entrySet()) {
            if (!resolver.breakdownOf(support.require(item.getKey())).effective().equals(item.getValue())) {
                throw conflict("恢复后的个人操作权限与预览不一致，整批已回滚，请重新预览");
            }
        }
        if (changed) audit.record("permission_configuration_import", "permissions", "configuration",
                plan.users.keySet().stream().map(UUID::toString).toList(),List.of(),
                Map.of("configurationHash",hash(commit.request().configuration()),"previewFingerprint",commit.expectedFingerprint(),
                        "departmentCount",plan.departments.size(),"userCount",plan.users.size(),"dataScopes",commit.request().importDataScopes(),
                        "departmentMappings",list(commit.request().departments()),"userMappings",list(commit.request().users()),
                        "ownerMappings",commit.request().importDataScopes() ? list(commit.request().owners()) : List.of(),"changes",plan.preview().changes()));
        // 恢复为备份快照后，这些账号的配置不再源于模板：解除持续绑定。
        templateBindings.clearForUsers(plan.users.keySet());
        return new Result(changed,plan.preview().changes());
    }

    @Transactional(readOnly=true, isolation=Isolation.REPEATABLE_READ)
    public CopySnapshot copySnapshot(UUID sourceId) {
        requireActor();
        UserAccount source = eligibleUser(sourceId);
        var breakdown = resolver.breakdownOf(source);
        String label = userLabel(sourceId);
        List<String> codes = sorted(breakdown.effective());
        return new CopySnapshot(sourceId,label,codes,hash(List.of(sourceId,sourceIdentityFingerprint(sourceId),catalogFingerprint(),codes)),sorted(breakdown.managerGrants()));
    }

    @Transactional(readOnly=true, isolation=Isolation.REPEATABLE_READ)
    public Preview previewCopy(UUID targetId, CopyRequest request) {
        requireActor();
        return copyPlan(targetId,request).preview();
    }

    @Transactional
    public Result copyPermissions(UUID targetId, CopyCommit commit) {
        lockConfiguration();
        requireActor();
        Plan plan = copyPlan(targetId,commit.request());
        confirm(plan.preview(),commit.expectedFingerprint(),commit.sensitiveConfirmations());
        tx.bind();
        OverrideConfiguration raw=plan.overrides.get(targetId);
        boolean detached=templateBindings.list().stream().anyMatch(binding->binding.kind().equals("user") && binding.targetId().equals(targetId));
        templateBindings.clearForUsers(List.of(targetId));
        var change = overrideAdmin.restoreExactPermissionOverrides(targetId,raw.grants(),raw.revokes(),plan.users.get(targetId));
        // 整份复制后配置不再源于模板：解除持续绑定，模板后续修改不再同步到该账号。
        if (!change.isEmpty()) templateBindings.clearForUsers(List.of(targetId));
        if (!change.isEmpty() || detached) audit.record("permission_configuration_copy", "users",targetId.toString(),change.added(),change.removed(),
                Map.of("sourceUserId",commit.request().sourceUserId().toString(),"previewFingerprint",commit.expectedFingerprint()));
        return new Result(!change.isEmpty() || detached,plan.preview().changes());
    }

    private Plan copyPlan(UUID targetId, CopyRequest request) {
        if (request == null) throw invalid("缺少复制来源");
        if (request.sourceUserId() == null) throw invalid("缺少复制来源");
        Plan plan = new Plan();
        CopySnapshot source = copySnapshot(request.sourceUserId());
        if (!Objects.equals(source.fingerprint(),request.sourceFingerprint())) plan.issues.add("复制来源或权限配置已变化，请重新复制后预览");
        if (targetId.equals(request.sourceUserId())) plan.issues.add("请选择另一位员工粘贴权限");
        try {
            UserAccount target = eligibleUser(targetId);
            support.requireAuthorizationTarget(target);
            var current=resolver.breakdownOf(target);
            Set<String> keepGrants=new TreeSet<>(current.grants());keepGrants.retainAll(source.permissions());
            Set<String> keepRevokes=new TreeSet<>(current.revokes());keepRevokes.removeAll(source.permissions());
            addUser(plan,request.sourceUserId().toString(),target,source.permissions(),keepGrants,keepRevokes,catalog());
        } catch (ApiException exception) { plan.issues.add(exception.getMessage()); }
        addDelegationImpacts(plan);
        plan.fingerprint = hash(List.of("copy",targetId,request,stateFingerprint()));
        return plan;
    }

    private Plan importPlan(ImportRequest request) {
        if (request == null) throw invalid("缺少导入配置");
        validateBackup(request.configuration());
        checkMappings(request.departments(),1000); checkMappings(request.users(),1000); checkMappings(request.owners(),5000);
        Plan plan = new Plan();
        Backup backup = request.configuration();
        Map<String,Permission> catalog = catalog();
        Map<String,DepartmentConfiguration> sourceDepartments = index(backup.departments(),DepartmentConfiguration::key);
        Map<String,UserConfiguration> sourceUsers = index(backup.users(),UserConfiguration::key);
        Map<String,ScopeOwner> sourceOwners = index(backup.scopeOwners(),ScopeOwner::key);
        plan.suggestions.addAll(suggestions(backup));
        if (request.importBaseline()) {
            Set<String> desired = new TreeSet<>(backup.baseline());
            var pinned = permissions.findBaselinePinnedCodes();
            plan.pinned.addAll(difference(pinned,desired)); desired.addAll(pinned);
            validateCodes(desired,catalog,"全员基础包",plan.issues,GrantPolicy::baselineEligible);
            plan.baseline = desired;
            addChange(plan,"baseline","baseline",null,"全员基础包",permissions.findBaselineCodes(),desired,catalog);
        }
        for (Mapping mapping : list(request.departments())) {
            DepartmentConfiguration source = sourceDepartments.get(mapping.sourceKey());
            if (source == null) { plan.issues.add("备份中没有部门来源："+mapping.sourceKey()); continue; }
            if (mapping.targetId() == null) { plan.issues.add("部门尚未匹配："+source.code()+" "+source.name()); continue; }
            Object[] target = department(mapping.targetId());
            if (target == null) { plan.issues.add("目标部门不存在："+source.name()); continue; }
            String label = string(target[1])+" "+string(target[2]);
            validateCodes(source.permissions(),catalog,label,plan.issues,GrantPolicy::departmentGrantable);
            plan.departments.put(mapping.targetId(),new TreeSet<>(source.permissions()));
            addChange(plan,"department",source.key(),mapping.targetId(),label,
                    departmentGrants.findPermissionCodesByDepartmentId(mapping.targetId()),source.permissions(),catalog);
        }
        Map<String,UUID> ownerMappings = new HashMap<>();
        for (Mapping mapping : list(request.owners())) {
            if (!sourceOwners.containsKey(mapping.sourceKey())) plan.issues.add("备份中没有数据范围归属人："+mapping.sourceKey());
            ownerMappings.put(mapping.sourceKey(),mapping.targetId());
        }
        for (Mapping mapping : list(request.users())) {
            UserConfiguration source = sourceUsers.get(mapping.sourceKey());
            if (source == null) { plan.issues.add("备份中没有人员来源："+mapping.sourceKey()); continue; }
            if(Boolean.FALSE.equals(source.restorable()) || "disabled".equals(source.accountStatus())
                    || source.employeeStatus()!=null && !CurrentEmployeeStatusPolicy.isCurrentEmployee(source.employeeStatus())) {
                plan.issues.add(source.employeeName()+"：仅供审阅的停用或离职账号配置不能自动恢复"); continue;
            }
            Set<String> referencedCodes=new TreeSet<>(source.grants());
            referencedCodes.addAll(source.revokes()); referencedCodes.addAll(source.delegationPermissions());
            for(String code:referencedCodes) if(!catalog.containsKey(code)) plan.issues.add(source.employeeName()+"：来源参考中有目标系统不认识的权限码 "+code);
            if (mapping.targetId() == null) { plan.issues.add("人员尚未匹配："+source.employeeCode()+" "+source.employeeName()); continue; }
            try {
                UserAccount target = eligibleUser(mapping.targetId());
                support.requireAuthorizationTarget(target);
                addUser(plan,source.key(),target,source.effective(),source.grants(),source.revokes(),catalog);
                if (request.importDataScopes()) {
                    Map<String,List<UUID>> scopes = new TreeMap<>();
                    for (String scope : scopeCodes()) {
                        List<UUID> desired = new ArrayList<>();
                        for (String sourceOwnerKey : source.dataScopes().getOrDefault(scope,List.of())) {
                            UUID ownerId = ownerMappings.get(sourceOwnerKey);
                            if (ownerId == null || owner(ownerId) == null) {
                                ScopeOwner ref = sourceOwners.get(sourceOwnerKey);
                                plan.issues.add("数据范围归属人尚未匹配："+(ref == null ? sourceOwnerKey : ref.code()+" "+ref.name()));
                            } else desired.add(ownerId);
                        }
                        scopes.put(scope,desired.stream().distinct().sorted().toList());
                        List<UUID> current = scopeAdmin.getDataScopes(target.getId(),scope);
                        plan.changes.add(new Change("owner",source.key(),target.getId(),userLabel(target.getId())+" · "+scopeLabel(scope),
                                difference(desired,current).stream().map(this::ownerLabel).toList(),
                                difference(current,desired).stream().map(this::ownerLabel).toList()));
                    }
                    plan.scopes.put(target.getId(),scopes);
                }
            } catch (ApiException exception) { plan.issues.add(exception.getMessage()); }
        }
        if (plan.baseline == null && list(request.departments()).isEmpty() && list(request.users()).isEmpty()) plan.issues.add("请至少选择一项要恢复的配置");
        addDelegationImpacts(plan);
        plan.fingerprint = hash(List.of("import",request,stateFingerprint()));
        return plan;
    }

    private void addUser(Plan plan, String sourceKey, UserAccount target, Collection<String> effective,
            Collection<String> preservedGrants,Collection<String> preservedRevokes,Map<String,Permission> catalog) {
        validateCodes(effective,catalog,userLabel(target.getId()),plan.issues,GrantPolicy::individuallyGrantable);
        Set<String> desired = new TreeSet<>(effective);
        if (!new PermissionDependencyCatalog(catalog.values()).usablePermissions(desired).equals(desired)) {
            plan.issues.add(userLabel(target.getId())+"：快照缺少必需查看权限，请用相同或更新版本重新导出");
        }
        plan.users.put(target.getId(),desired);
        addChange(plan,"user",sourceKey,target.getId(),userLabel(target.getId()),resolver.breakdownOf(target).effective(),desired,catalog);
        Set<String> baseInherited = inheritedWithoutDelegations(target,plan);
        var breakdown = resolver.breakdownOf(target);
        Set<String> grants=new TreeSet<>(preservedGrants);
        grants.addAll(difference(desired,baseInherited));
        Set<String> inherited=new TreeSet<>(baseInherited);inherited.addAll(breakdown.managerGrants());
        Set<String> revokes=new TreeSet<>(preservedRevokes);
        Set<String> inheritedExtras=new TreeSet<>(difference(inherited,desired));inheritedExtras.removeAll(grants);
        revokes.addAll(inheritedExtras);
        if(!Collections.disjoint(grants,revokes)) plan.issues.add(userLabel(target.getId())+"：原始加授与收回互相冲突，不能静默改写");
        validateCodes(grants,catalog,userLabel(target.getId()),plan.issues,GrantPolicy::individuallyGrantable);
        Set<String> predicted=new TreeSet<>(inherited);predicted.addAll(grants);predicted.removeAll(revokes);
        if(!new PermissionDependencyCatalog(catalog.values()).usablePermissions(predicted).equals(desired)) {
            plan.issues.add(userLabel(target.getId())+"：原始个人策略与目标继承/操作依赖无法同时保持，请调整映射或先核对原配置");
        }
        plan.overrides.put(target.getId(),new OverrideConfiguration(Set.copyOf(grants),Set.copyOf(revokes)));
        Map<String,String> previous=new TreeMap<>(),next=new TreeMap<>();
        breakdown.grants().forEach(code->previous.put(code,"grant"));breakdown.revokes().forEach(code->previous.put(code,"revoke"));
        grants.forEach(code->next.put(code,"grant"));revokes.forEach(code->next.put(code,"revoke"));
        List<String> added=new ArrayList<>(),removed=new ArrayList<>();
        previous.forEach((code,effect)->{if(!effect.equals(next.get(code))) removed.add(overrideLabel(code,effect,catalog));});
        next.forEach((code,effect)->{
            if(!effect.equals(previous.get(code))) added.add(overrideLabel(code,effect,catalog));
            else if((effect.equals("grant") && !breakdown.confirmedGrants().contains(code))
                    || effect.equals("revoke") && breakdown.legacyUnknownRevokes().contains(code)) {
                added.add("重新确认"+overrideLabel(code,effect,catalog));
            }
        });
        if(!added.isEmpty() || !removed.isEmpty()) {
            plan.changedGrantors.add(target.getId());
            plan.changes.add(new Change("user",sourceKey,target.getId(),userLabel(target.getId())+" · 个人覆盖与授权来源",List.copyOf(added),List.copyOf(removed)));
        }
        for (String code : grants) {
            if (breakdown.confirmedGrants().contains(code)) continue;
            Permission permission = catalog.get(code);
            if (permission == null) continue;
            addSensitive(plan,"user",target.getId(),userLabel(target.getId()),permission);
        }
    }

    private String overrideLabel(String code,String effect,Map<String,Permission> catalog) {
        return (effect.equals("grant")?"个人加授：":"个人收回：")+(catalog.containsKey(code)?catalog.get(code).getName():code)+" ("+code+")";
    }

    private List<StoredOverride> storedOverrides(UUID userId) {
        return rowsById("""
                SELECT p.code,o.effect,o.active,o.authority_source FROM user_permission_overrides o
                JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=:id ORDER BY p.code
                """,userId).stream().map(row->new StoredOverride(string(row[0]),string(row[1]),Boolean.TRUE.equals(row[2]),string(row[3]))).toList();
    }

    /** Do not repair stale delegation generations: disclose every currently valid contribution affected by this command. */
    private void addDelegationImpacts(Plan plan) {
        boolean global=plan.changes.stream().anyMatch(change->Set.of("department","baseline").contains(change.kind())
                && (!change.added().isEmpty() || !change.removed().isEmpty()));
        if(!global && plan.changedGrantors.isEmpty()) return;
        Map<UUID,Set<String>> affected=new TreeMap<>();
        for(Object[] row:rows("""
                SELECT d.user_id,d.granted_by_user_id,p.code FROM manager_permission_delegations d
                JOIN permissions p ON p.id=d.permission_id WHERE d.enabled ORDER BY d.user_id,p.code
                """)) {
            if(global || plan.changedGrantors.contains((UUID)row[1])) affected.computeIfAbsent((UUID)row[0],ignored->new TreeSet<>()).add(string(row[2]));
        }
        for(var entry:affected.entrySet()) {
            try {
                UserAccount recipient=eligibleUser(entry.getKey());
                Set<String> codes=new TreeSet<>(resolver.breakdownOf(recipient).managerGrants());codes.retainAll(entry.getValue());
                if(!codes.isEmpty()) plan.changes.add(new Change("user","delegation-impact",recipient.getId(),
                        userLabel(recipient.getId())+"：负责人委派来源失效（实际操作权限仍由其他来源共同决定）",List.of(),sorted(codes)));
            } catch(ApiException ignored) { /* Ineligible recipients have no currently usable delegation. */ }
        }
    }

    private Set<String> departmentConfigurationCodes(UUID id) {
        Set<String> codes=new TreeSet<>(departmentGrants.findPermissionCodesByDepartmentId(id));
        codes.addAll(permissions.findDepartmentTemplateCodes(id));return codes;
    }

    private Set<String> inheritedWithoutDelegations(UserAccount target,Plan plan) {
        Set<String> result = new TreeSet<>(plan.baseline == null ? permissions.findBaselineCodes() : plan.baseline);
        @SuppressWarnings("unchecked")
        List<UUID> ancestors = em.createNativeQuery("""
                WITH RECURSIVE ancestors AS (
                    SELECT d.id,d.parent_id FROM departments d WHERE d.id IN (
                        SELECT department_id FROM employees WHERE id=:id
                        UNION SELECT department_id FROM employee_secondary_departments WHERE employee_id=:id)
                    UNION SELECT d.id,d.parent_id FROM departments d JOIN ancestors a ON d.id=a.parent_id
                ) SELECT id FROM ancestors
                """).setParameter("id",target.getEmployeeId()).getResultList();
        for (UUID id : ancestors) result.addAll(plan.departments.containsKey(id) ? plan.departments.get(id) : departmentConfigurationCodes(id));
        return result;
    }

    private void addChange(Plan plan,String kind,String sourceKey,UUID targetId,String label,Collection<String> current,
            Collection<String> desired,Map<String,Permission> catalog) {
        List<String> added = difference(desired,current);
        plan.changes.add(new Change(kind,sourceKey,targetId,label,added,difference(current,desired)));
        for (String code : added) {
            Permission permission = catalog.get(code);
            if (permission != null) addSensitive(plan,kind,targetId,label,permission);
        }
    }

    private void addSensitive(Plan plan,String kind,UUID targetId,String label,Permission permission) {
        if (GrantPolicy.bulkEligible(permission.grantPolicies())) return;
        String key=kind+":"+(targetId == null ? "baseline" : targetId)+":"+permission.getCode();
        if (plan.sensitive.stream().noneMatch(item->item.key().equals(key))) {
            plan.sensitive.add(new SensitiveAddition(key,permission.getName(),permission.getCode(),label));
        }
    }

    private List<Suggestion> suggestions(Backup backup) {
        List<Suggestion> result = new ArrayList<>();
        SuggestionIdentitySupport identitySupport=suggestionIdentitySupport();
        for (var source : backup.departments()) {
            List<Object[]> matches = rows("SELECT id,code,name FROM departments WHERE NOT is_deleted AND code=:code",source.code());
            result.add(suggestion("department",source.key(),matches));
        }
        for (var source : backup.users()) {
            List<Object[]> matches=List.of();
            UUID original=sourceUuid(source.key());
            if(original!=null && identitySupport.retainedUser()) {
                UUID retained=(UUID)em.createNativeQuery("SELECT public.fn_employee_merge_retained_user(:id)")
                        .setParameter("id",original).getSingleResult();
                if(retained!=null) {
                    List<Object[]> byIdentity=rowsById(USER_SUGGESTION_SQL+" AND u.id=:id",retained);
                    // Portable source keys remain hints: a live, unmerged UUID
                    // must also match its current employee code. A retired UUID
                    // may resolve to its verified retained person at another code.
                    if(!retained.equals(original) || sameSuggestionCode(byIdentity,source.employeeCode())) matches=byIdentity;
                }
            }
            boolean identityRequired=matches.isEmpty() && retiredSuggestionCode(identitySupport,source.employeeCode());
            if(matches.isEmpty() && !identityRequired)
                matches=rows(USER_SUGGESTION_SQL+" AND e.code=:code",source.employeeCode());
            result.add(identityRequired?new Suggestion("user",source.key(),null,"该工号已释放或复用，请按原人员身份手动选择")
                    :suggestion("user",source.key(),matches));
        }
        for (var source : backup.scopeOwners()) {
            List<Object[]> matches=List.of();
            UUID original=sourceUuid(source.key());
            if(original!=null && identitySupport.canonicalEmployee()) {
                UUID retained=(UUID)em.createNativeQuery("SELECT public.fn_canonical_employee_identity(:id)")
                        .setParameter("id",original).getSingleResult();
                if(retained!=null) {
                    List<Object[]> byIdentity=rowsById("SELECT id,code,full_name FROM employees WHERE NOT is_deleted AND id=:id",retained);
                    if(!retained.equals(original) || sameSuggestionCode(byIdentity,source.code())) matches=byIdentity;
                }
            }
            boolean identityRequired=matches.isEmpty() && retiredSuggestionCode(identitySupport,source.code());
            if(matches.isEmpty() && !identityRequired)
                matches=rows("SELECT id,code,full_name FROM employees WHERE NOT is_deleted AND code=:code",source.code());
            result.add(identityRequired?new Suggestion("owner",source.key(),null,"该工号已释放或复用，请按原人员身份手动选择")
                    :suggestion("owner",source.key(),matches));
        }
        return result;
    }

    private static final String USER_SUGGESTION_SQL="""
            SELECT u.id,e.code,e.full_name FROM users u JOIN employees e ON e.id=u.employee_id
            WHERE NOT u.is_deleted AND NOT u.is_super_admin AND u.status='active' AND NOT e.is_deleted
            AND e.status IN ('active','probation','onLeave')
            """;
    private record SuggestionIdentitySupport(boolean canonicalEmployee,boolean retainedUser,boolean retiredCode,boolean mergeTable) { }
    private SuggestionIdentitySupport suggestionIdentitySupport() {
        Object[] flags=(Object[])em.createNativeQuery("""
            SELECT to_regprocedure('public.fn_canonical_employee_identity(uuid)') IS NOT NULL,
                   to_regprocedure('public.fn_employee_merge_retained_user(uuid)') IS NOT NULL,
                   to_regprocedure('public.fn_employee_code_requires_identity_mapping(text)') IS NOT NULL,
                   to_regclass('public.employee_identity_merges') IS NOT NULL
            """).getSingleResult();
        return new SuggestionIdentitySupport(Boolean.TRUE.equals(flags[0]),Boolean.TRUE.equals(flags[1]),
                Boolean.TRUE.equals(flags[2]),Boolean.TRUE.equals(flags[3]));
    }
    private boolean retiredSuggestionCode(SuggestionIdentitySupport support,String code) {
        if(support.retiredCode()) return Boolean.TRUE.equals(em.createNativeQuery("SELECT public.fn_employee_code_requires_identity_mapping(:code)")
                .setParameter("code",code).getSingleResult());
        if(support.mergeTable()) return Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM public.employee_identity_merges WHERE upper(btrim(source_code))=upper(btrim(CAST(:code AS text))))")
                .setParameter("code",code).getSingleResult());
        return false;
    }
    private static UUID sourceUuid(String key) {
        try{return key==null?null:UUID.fromString(key);}catch(IllegalArgumentException ignored){return null;}
    }
    private static boolean sameSuggestionCode(List<Object[]> matches,String sourceCode) {
        return matches.size()==1 && Objects.equals(string(matches.getFirst()[1]).strip().toUpperCase(Locale.ROOT),
                string(sourceCode).strip().toUpperCase(Locale.ROOT));
    }

    private Suggestion suggestion(String kind,String key,List<Object[]> matches) {
        return matches.size()==1 ? new Suggestion(kind,key,(UUID)matches.getFirst()[0],string(matches.getFirst()[1])+" "+string(matches.getFirst()[2]))
                : new Suggestion(kind,key,null,"未找到唯一编号匹配，请手动选择");
    }

    private void validateCodes(Collection<String> codes,Map<String,Permission> catalog,String label,List<String> issues,
            java.util.function.Predicate<Set<GrantPolicy>> allowed) {
        for (String code : codes) {
            Permission permission = catalog.get(code);
            if (permission == null) issues.add(label+"：目标系统没有权限码 "+code);
            else if (!allowed.test(permission.grantPolicies())) issues.add(label+"：此入口不能授予 "+permission.getName()+" ("+code+")");
        }
    }

    private void confirm(Preview preview,String expected,List<String> confirmations) {
        if (expected == null || !MessageDigest.isEqual(preview.fingerprint().getBytes(StandardCharsets.UTF_8),expected.getBytes(StandardCharsets.UTF_8))) {
            throw conflict("配置、匹配对象或权限已变化，请重新预览后确认");
        }
        if (!preview.canApply()) throw invalid(String.join("；",preview.issues()));
        Set<String> confirmed = new HashSet<>(list(confirmations));
        if (!confirmed.containsAll(preview.sensitiveAdditions().stream().map(SensitiveAddition::key).toList())) {
            throw invalid("请逐项确认本次新增的敏感权限");
        }
    }

    /** Existing baseline/scope editors hold these keys before touching tables. Acquire the same keys first, without waiting. */
    private void lockExistingEntryPoints(ImportRequest request) {
        if (request == null) return;
        Set<String> keys=new TreeSet<>();
        if(request.importBaseline()) keys.add("PERMISSION_BASELINE");
        if(request.importDataScopes()) {
            checkMappings(request.users(),1000);
            for(Mapping mapping:list(request.users())) if(mapping.targetId()!=null) {
                for(String scope:scopeCodes()) keys.add(mapping.targetId()+":"+scope);
            }
        }
        for(String key:keys) {
            Object locked=em.createNativeQuery("SELECT pg_try_advisory_xact_lock(hashtextextended(CAST(:lockKey AS text),0))")
                    .setParameter("lockKey",key).getSingleResult();
            if(!Boolean.TRUE.equals(locked)) throw conflict(key.equals("PERMISSION_BASELINE")
                    ? "其他管理员正在修改全员基础权限，本次尚未修改，请稍后重新预览"
                    : "其他管理员正在修改数据范围，本次尚未修改，请稍后重新预览");
        }
    }

    /** NOWAIT also excludes pre-existing FOR UPDATE/SHARE readers; ordinary reads remain available. */
    void lockConfiguration() {
        try {
            em.createNativeQuery("""
                    LOCK TABLE public.authorization_state,public.departments,public.department_permissions,
                    public.employees,public.employee_secondary_departments,public.employment_history,
                    public.manager_permission_delegations,public.organization_permission_leader_assignments,
                    public.permissions,public.permission_surfaces,public.permission_surface_permissions,
                    public.system_settings,public.users,public.user_permission_overrides,public.user_data_scopes,
                    public.permission_templates,public.permission_template_applies,
                    public.user_permission_template_bindings,public.department_permission_template_bindings
                    IN EXCLUSIVE MODE NOWAIT
                    """).executeUpdate();
        } catch (RuntimeException exception) {
            throw conflict("其他人正在修改账号、组织或权限，本次尚未修改，请稍后重新预览");
        }
        em.clear();
    }

    void requireActor() {
        support.requireCurrentSuperAdmin();
        var principal = support.requireCurrentUser();
        UserAccount actor = support.require(principal.getId());
        if (!actor.isSuperAdmin() || !"active".equals(actor.getStatus()) || principal.getImpersonatedBy()!=null
                || principal.isMustChangePassword() || actor.isMustChangePassword()) {
            throw new ApiException(ErrorCode.FORBIDDEN,"仅已完成改密的在职超级管理员本人可迁移权限");
        }
        Object[] employee = owner(actor.getEmployeeId());
        if (employee == null || !CurrentEmployeeStatusPolicy.isCurrentEmployee(string(employee[3]))) {
            throw new ApiException(ErrorCode.FORBIDDEN,"操作人已离职或员工档案无效");
        }
    }

    private UserAccount eligibleUser(UUID id) {
        UserAccount user = support.require(id);
        if (user.isSuperAdmin()) throw invalid("不能复制或恢复超级管理员身份产生的全量权限");
        Object[] employee = owner(user.getEmployeeId());
        if (!"active".equals(user.getStatus()) || employee==null || !CurrentEmployeeStatusPolicy.isCurrentEmployee(string(employee[3]))) {
            throw invalid("目标或来源账号未启用、已离职或员工档案无效");
        }
        return user;
    }

    private Map<String,Permission> catalog() { return permissions.findAll().stream().collect(Collectors.toMap(Permission::getCode,Function.identity())); }
    private List<String> scopeCodes() { return scopeCatalog.list().stream().map(com.uten.imp.features.admin.dto.DataScopeDefinitionDto::scope).toList(); }
    private String scopeLabel(String code) { return scopeCatalog.list().stream().filter(scope->scope.scope().equals(code)).findFirst().orElseThrow().label(); }
    private Object[] department(UUID id) { return first(rowsById("SELECT id,code,name FROM departments WHERE id=:id AND NOT is_deleted",id)); }
    private Object[] owner(UUID id) { return first(rowsById("SELECT id,code,full_name,status FROM employees WHERE id=:id AND NOT is_deleted",id)); }
    private String ownerLabel(UUID id) { Object[] row=owner(id); return row==null ? id.toString() : string(row[1])+" "+string(row[2]); }
    private String userLabel(UUID id) { var user=support.require(id); return ownerLabel(user.getEmployeeId())+" ("+user.getLoginAccount()+")"; }
    @SuppressWarnings("unchecked") private List<Object[]> rows(String sql) { return em.createNativeQuery(sql).getResultList(); }
    @SuppressWarnings("unchecked") private List<Object[]> rows(String sql,String code) { return em.createNativeQuery(sql).setParameter("code",code).getResultList(); }
    @SuppressWarnings("unchecked") private List<Object[]> rowsById(String sql,UUID id) { return em.createNativeQuery(sql).setParameter("id",id).getResultList(); }
    private static Object[] first(List<Object[]> rows) { return rows.isEmpty()?null:rows.getFirst(); }
    private static String string(Object value) { return value==null?"":value.toString(); }
    private static <T> List<T> list(List<T> value) { return value==null?List.of():value; }
    private static List<String> sorted(Collection<String> values) { return values.stream().distinct().sorted().toList(); }
    private static <T extends Comparable<? super T>> List<T> difference(Collection<T> a,Collection<T> b) { var result=new TreeSet<>(a); result.removeAll(b); return List.copyOf(result); }
    private static <T> Map<String,T> index(List<T> values,Function<T,String> key) { return values.stream().collect(Collectors.toMap(key,Function.identity())); }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED,message); }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }

    /** Digest only authorization inputs; credentials and session activity never leave the database or enter the file. */
    String stateFingerprint() {
        return string(em.createNativeQuery("""
                SELECT md5(jsonb_build_object(
                  'epoch',(SELECT to_jsonb(a) FROM authorization_state a WHERE singleton_id=1),
                  'departments',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id) FROM departments d),
                  'employees',(SELECT jsonb_agg(jsonb_build_array(e.id,e.code,e.full_name,e.department_id,e.status,e.is_deleted,e.permission_delegation_generation) ORDER BY e.id) FROM employees e),
                  'users',(SELECT jsonb_agg(jsonb_build_array(u.id,u.employee_id,u.login_account,u.status,u.is_deleted,u.is_super_admin,u.auth_version,u.permission_delegation_generation) ORDER BY u.id) FROM users u),
                  'secondary',(SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM employee_secondary_departments s),
                  'permissions',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.code) FROM permissions p),
                  'surfaces',(SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM permission_surfaces s),
                  'surfacePermissions',(SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM permission_surface_permissions s),
                  'departmentGrants',(SELECT jsonb_agg(to_jsonb(g) ORDER BY g.department_id,g.permission_id) FROM department_permissions g),
                  'overrides',(SELECT jsonb_agg(to_jsonb(o) ORDER BY o.user_id,o.permission_id) FROM user_permission_overrides o),
                  'delegations',(SELECT jsonb_agg(to_jsonb(d) ORDER BY to_jsonb(d)::text) FROM manager_permission_delegations d),
                  'leaders',(SELECT jsonb_agg(to_jsonb(l) ORDER BY to_jsonb(l)::text) FROM organization_permission_leader_assignments l),
                  'scopes',(SELECT jsonb_agg(to_jsonb(s) ORDER BY s.user_id,s.scope,s.owner_employee_id) FROM user_data_scopes s),
                  'rehire',(SELECT jsonb_agg(jsonb_build_array(h.employee_id,h.id) ORDER BY h.id) FROM employment_history h WHERE h.event_type='rehire'),
                  'templates',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM permission_templates t),
                  'userTemplates',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.user_id) FROM user_permission_template_bindings t),
                  'departmentTemplates',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.department_id) FROM department_permission_template_bindings t),
                  'legacyTemplates',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.user_id) FROM permission_template_applies t),
                  'settings',(SELECT jsonb_agg(jsonb_build_array(s.key,s.value) ORDER BY s.key) FROM system_settings s WHERE s.key LIKE '%permission%')
                )::text)
                """).getSingleResult());
    }

    private String sourceIdentityFingerprint(UUID sourceId) {
        return string(em.createNativeQuery("""
                SELECT md5(jsonb_build_array(u.id,u.employee_id,u.status,u.is_deleted,u.is_super_admin,
                    u.auth_version,u.permission_delegation_generation,e.code,e.full_name,e.department_id,
                    e.status,e.is_deleted,e.permission_delegation_generation,
                    (SELECT count(*) FROM employment_history h WHERE h.employee_id=e.id AND h.event_type='rehire'))::text)
                FROM users u JOIN employees e ON e.id=u.employee_id WHERE u.id=:id
                """).setParameter("id",sourceId).getSingleResult());
    }

    private String catalogFingerprint() {
        return string(em.createNativeQuery("""
                SELECT md5(coalesce(jsonb_agg(jsonb_build_array(p.code,p.grant_policy,p.action_type,p.sensitivity,p.high_risk,p.baseline,p.baseline_pinned)
                    ORDER BY p.code),'[]'::jsonb)::text) FROM permissions p
                """).getSingleResult());
    }

    private String hash(Object value) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(mapper.writeValueAsBytes(value))); }
        catch (Exception exception) { throw new IllegalStateException("Cannot fingerprint permission configuration",exception); }
    }

    private void validateBackup(Backup backup) {
        if (backup==null || !FORMAT.equals(backup.format()) || backup.version()!=1) throw invalid("不是受支持的权限备份文件（需要版本 1）");
        if (backup.departments()==null || backup.users()==null || backup.scopeOwners()==null || backup.baseline()==null) throw invalid("权限备份缺少必需字段");
        if (backup.departments().size()>1000 || backup.users().size()>1000 || backup.scopeOwners().size()>5000) throw invalid("权限备份对象数量超过上限");
        try { if (mapper.writeValueAsBytes(backup).length>16*1024*1024) throw invalid("权限备份不能超过 16 MiB"); }
        catch (com.fasterxml.jackson.core.JsonProcessingException exception) { throw invalid("权限备份格式错误"); }
        codes(backup.baseline());
        Set<String> keys=new HashSet<>();
        for (var department : backup.departments()) {
            if (department==null) throw invalid("部门配置不能为空");
            key(department.key(),keys); text(department.code()); text(department.name()); codes(department.permissions());
        }
        keys.clear();
        for (var owner : backup.scopeOwners()) {
            if (owner==null) throw invalid("数据范围归属人不能为空");
            key(owner.key(),keys); text(owner.code()); text(owner.name());
        }
        Set<String> ownerKeys=Set.copyOf(keys); keys.clear();
        for (var user : backup.users()) {
            if (user==null) throw invalid("人员配置不能为空");
            key(user.key(),keys); text(user.employeeCode()); text(user.employeeName()); text(user.loginAccount());
            codes(user.grants()); codes(user.revokes()); codes(user.effective()); codes(user.delegationPermissions());
            if(user.storedOverrides()!=null) {
                if(user.storedOverrides().size()>3000) throw invalid("留存覆盖数量超过上限");
                Set<String> storedCodes=new HashSet<>();
                for(StoredOverride row:user.storedOverrides()) {
                    if(row==null || row.code()==null || row.effect()==null || !Set.of("grant","revoke").contains(row.effect())) throw invalid("留存覆盖格式错误");
                    codes(List.of(row.code()));key(row.code(),storedCodes);text(row.authoritySource());
                }
            }
            if (user.dataScopes()==null || !scopeCodes().containsAll(user.dataScopes().keySet())) throw invalid("未知或缺少数据范围配置");
            for (var values : user.dataScopes().values()) {
                if (values==null || values.size()>5000 || values.stream().anyMatch(value -> !ownerKeys.contains(value))) throw invalid("数据范围引用了未登记归属人");
                if (new HashSet<>(values).size()!=values.size()) throw invalid("数据范围归属人重复");
            }
        }
    }
    private static void codes(List<String> values) {
        if (values==null || values.size()>3000) throw invalid("权限码列表缺失或超过上限");
        for(String code:values) if(code==null || code.isBlank() || code.length()>128) throw invalid("权限码格式错误");
        if(new HashSet<>(values).size()!=values.size()) throw invalid("权限码重复");
    }
    private static void text(String value) { if(value==null || value.isBlank() || value.length()>256) throw invalid("来源编号或名称缺失或过长"); }
    private static void key(String key,Set<String> keys) { text(key); if(!keys.add(key)) throw invalid("备份中来源键重复："+key); }
    private static void checkMappings(List<Mapping> mappings,int maximum) {
        if(list(mappings).size()>maximum) throw invalid("匹配对象数量超过上限");
        Set<String> keys=new HashSet<>(); Set<UUID> targets=new HashSet<>();
        for(Mapping mapping:list(mappings)) {
            if(mapping==null) throw invalid("匹配项目不能为空");
            key(mapping.sourceKey(),keys);
            if(mapping.targetId()!=null && !targets.add(mapping.targetId())) throw invalid("多个来源不能同时覆盖同一个目标");
        }
    }

    private static final class Plan {
        private String fingerprint;
        private List<String> notes=NOTES;
        private Set<String> baseline;
        private final Map<UUID,Set<String>> departments=new TreeMap<>();
        private final Map<UUID,Set<String>> users=new TreeMap<>();
        private final Map<UUID,OverrideConfiguration> overrides=new TreeMap<>();
        private final Set<UUID> changedGrantors=new TreeSet<>();
        private final Map<UUID,Map<String,List<UUID>>> scopes=new TreeMap<>();
        private final List<String> issues=new ArrayList<>();
        private final List<Change> changes=new ArrayList<>();
        private final List<SensitiveAddition> sensitive=new ArrayList<>();
        private final List<Suggestion> suggestions=new ArrayList<>();
        private final List<String> pinned=new ArrayList<>();
        Preview preview() { return new Preview(fingerprint,issues.isEmpty(),List.copyOf(new LinkedHashSet<>(issues)),List.copyOf(changes),
                List.copyOf(sensitive),List.copyOf(suggestions),List.copyOf(pinned),notes); }
    }
    private record OverrideConfiguration(Set<String> grants,Set<String> revokes) {}
}
