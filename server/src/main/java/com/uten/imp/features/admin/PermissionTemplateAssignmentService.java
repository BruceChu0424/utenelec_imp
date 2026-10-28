package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionTemplateDtos.*;
import com.uten.imp.features.admin.dto.PermissionTransferDtos.*;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
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
import java.util.*;
import java.util.stream.Collectors;

/** One reviewed, atomic writer for employee/department source assignments and permission deltas. */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class PermissionTemplateAssignmentService {
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final PermissionConfigurationTransferService transfer;
    private final PermissionTemplateBindingService bindings;
    private final PermissionRepository permissions;
    private final DepartmentPermissionRepository departmentPermissions;
    private final PermissionResolver resolver;
    private final PermissionOverrideAdminService overrides;
    private final DepartmentPermissionAdminService departments;
    private final AdminUserSupport support;
    private final PermissionChangeAudit audit;
    private final TxSessionVars tx;

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public List<Binding> bindings() { transfer.requireActor(); return bindings.list(); }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Preview preview(BatchApply request) { transfer.requireActor(); return templatePlan(request).preview(); }

    @Transactional
    public Result apply(BatchCommit commit) {
        if(commit==null) throw invalid("缺少批量模板请求");
        transfer.lockConfiguration(); transfer.requireActor();
        Plan plan=templatePlan(commit.request());
        confirm(plan,commit.expectedFingerprint(),commit.sensitiveConfirmations());
        return write(plan,"permission_template_apply");
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Preview previewDelta(DeltaRequest request) { transfer.requireActor(); return deltaPlan(request).preview(); }

    @Transactional
    public Result applyDelta(DeltaCommit commit) {
        if(commit==null) throw invalid("缺少批量授权请求");
        transfer.lockConfiguration(); transfer.requireActor();
        Plan plan=deltaPlan(commit.request());
        confirm(plan,commit.expectedFingerprint(),commit.sensitiveConfirmations());
        return write(plan,"permission_configuration_batch");
    }

    @Transactional
    public Result unbind(Unbind request) {
        transfer.lockConfiguration(); transfer.requireActor(); tx.bind();
        Targets targets=targets(request==null?null:request.userIds(),request==null?null:request.departmentIds());
        List<Binding> current=bindings.list().stream().filter(binding->binding.kind().equals("user")
                ? targets.users.contains(binding.targetId()):targets.departments.contains(binding.targetId())).toList();
        requireExpectedBindings(request.expectedBindings(),targets,current);
        return detach(current);
    }

    private void requireExpectedBindings(List<ExpectedBinding> expected,Targets targets,List<Binding> current) {
        if(expected==null || expected.isEmpty() || expected.size()!=targets.users.size()+targets.departments.size()
                || expected.size()!=current.size()) throw staleBinding();
        Map<String,Binding> actual=current.stream().collect(Collectors.toMap(binding->binding.kind()+":"+binding.targetId(),binding->binding));
        Set<String> checked=new HashSet<>();
        for(ExpectedBinding seen:expected) {
            if(seen==null || seen.kind()==null || seen.targetId()==null || seen.templateId()==null
                    || seen.templateVersion()==null || seen.legacySnapshot()==null) throw staleBinding();
            String key=seen.kind()+":"+seen.targetId();Binding now=actual.get(key);
            if(!checked.add(key) || now==null || !now.templateId().equals(seen.templateId())
                    || now.templateVersion()!=seen.templateVersion() || now.legacySnapshot()!=seen.legacySnapshot()) throw staleBinding();
        }
    }
    private static ApiException staleBinding() { return conflict("模板关联已变化或确认信息不完整，请重新读取后确认解除关联"); }

    /** Template deletion freezes each live positive contribution; legacy snapshots already are manual. */
    void detachTemplate(UUID templateId) {
        detach(bindings.list().stream().filter(binding->binding.templateId().equals(templateId)).toList());
    }

    void validateLinkedDepartments(UUID templateId,Set<String> codes) {
        if(bindings.list().stream().noneMatch(binding->binding.kind().equals("department") && binding.templateId().equals(templateId))) return;
        Map<String,Permission> catalog=catalog();
        for(String code:codes) if(!GrantPolicy.departmentGrantable(catalog.get(code).grantPolicies())) {
            throw invalid("这个模板已关联部门，不能加入仅可逐人授予的权限："+catalog.get(code).getName());
        }
    }

    private Result detach(List<Binding> selected) {
        List<Change> changes=new ArrayList<>();
        for(Binding binding:selected) {
            UUID id=binding.targetId();
            if(binding.kind().equals("user")) {
                boolean preservable=((Number)em.createNativeQuery("""
                        SELECT count(*) FROM users u JOIN employees e ON e.id=u.employee_id
                        WHERE u.id=:id AND NOT u.is_deleted AND NOT u.is_super_admin
                          AND NOT e.is_deleted AND e.status IN ('active','probation','onLeave')
                        """).setParameter("id",id).getSingleResult()).longValue()>0
                        && !support.requireCurrentUser().getId().equals(id);
                if(!binding.legacySnapshot() && preservable) {
                    UserAccount account=support.require(id);
                    var before=resolver.breakdownOf(account);
                    Set<String> grants=new TreeSet<>(before.grants());
                    grants.addAll(before.templatePermissions()); grants.removeAll(before.revokes());
                    bindings.clearForUsers(List.of(id));
                    overrides.applyTemplateSourceConfiguration(id,grants,new TreeSet<>(before.revokes()),false);
                } else bindings.clearForUsers(List.of(id));
            } else {
                Set<String> codes=new TreeSet<>(departmentPermissions.findPermissionCodesByDepartmentId(id));
                codes.addAll(permissions.findDepartmentTemplateCodes(id));
                bindings.clearForDepartments(List.of(id));
                if(!rows("SELECT id,name FROM departments WHERE id=:id AND NOT is_deleted",id).isEmpty()) {
                    departments.restoreExactDepartmentPermissions(id,List.copyOf(codes));
                }
            }
            Change change=new Change(binding.kind(),binding.templateId().toString(),id,
                    binding.templateName()+"：解除关联并保留当前配置",List.of(),List.of("模板关联"));
            changes.add(change);
            audit.record("permission_template_unbind",binding.kind().equals("user")?"users":"departments",id.toString(),
                    List.of(),List.of(binding.templateId().toString()),Map.of("preservePermissions",true,"legacySnapshot",binding.legacySnapshot()));
        }
        return new Result(!changes.isEmpty(),List.copyOf(changes));
    }

    private Plan templatePlan(BatchApply request) {
        if(request==null || request.templateId()==null || request.templateVersion()==null || request.mode()==null) throw invalid("请选择模板、版本和应用方式");
        Targets targets=targets(request.userIds(),request.departmentIds());
        TemplateData template=template(request.templateId(),request.templateVersion());
        Map<String,Permission> catalog=catalog();
        validateCodes(template.codes,catalog,GrantPolicy::individuallyGrantable);
        Plan plan=new Plan(); plan.templateId=template.id;plan.existingBindings=bindings.list();
        plan.notes.add("模板是独立权限来源；修改模板会同步所有关联员工及部门，个人明确收回始终优先。一次提交全部成功或全部回滚。");
        plan.notes.add("替换直接设置会清除目标的手工加授并替换模板关联；全员基础、上级部门及个人收回继续保留。补充模式保留原有能力。");
        plan.notes.add("旧版快照不会猜测拆分来源；重新应用时建立独立关联，补充模式继续保留原快照中的个人配置。");
        if(!targets.departments.isEmpty()) plan.notes.add("部门配置变化会使现有负责人委派失效，请按最新权限重新委派。");
        for(UUID id:targets.departments) {
            try {
                requireDepartment(id);
                validateCodes(template.codes,catalog,GrantPolicy::departmentGrantable);
                Set<String> current=new TreeSet<>(departmentPermissions.findPermissionCodesByDepartmentId(id));
                Set<String> previousTemplate=new TreeSet<>(permissions.findDepartmentTemplateCodes(id));
                Set<String> manual=request.mode()==ApplyMode.REPLACE?new TreeSet<>():new TreeSet<>(current);
                if(request.mode()==ApplyMode.MERGE) manual.addAll(difference(previousTemplate,template.codes));
                Set<String> effective=union(manual,template.codes);
                TargetPlan target=new TargetPlan("department",id,manual,Set.of(),effective,template.id);
                plan.targets.add(target);
                addChange(plan,target,union(current,previousTemplate),effective,catalog);
                addBindingChange(plan,target,template);
            } catch(ApiException exception) { plan.issues.add(exception.getMessage()); }
        }
        for(UUID id:targets.users) {
            try {
                UserAccount account=eligibleUser(id);
                var before=resolver.breakdownOf(account);
                Set<String> inherited=inheritedFor(account,plan);
                if(targets.departments.isEmpty()) inherited.addAll(before.managerGrants());
                Set<String> grants=request.mode()==ApplyMode.REPLACE?new TreeSet<>():new TreeSet<>(before.grants());
                Set<String> revokes=new TreeSet<>(before.revokes());
                if(request.mode()==ApplyMode.MERGE) {
                    Set<String> retained=difference(before.templatePermissions(),template.codes);
                    retained.retainAll(before.effective()); grants.addAll(retained);
                }
                Set<String> effective=union(inherited,grants,template.codes);effective.removeAll(revokes);
                effective=new TreeSet<>(new PermissionDependencyCatalog(catalog.values()).usablePermissions(effective));
                TargetPlan target=new TargetPlan("user",id,grants,revokes,effective,template.id);
                plan.targets.add(target); addChange(plan,target,before.effective(),effective,catalog); addBindingChange(plan,target,template);
                if(!Collections.disjoint(template.codes,revokes)) plan.notes.add(label("user",id)+"：模板中已个人收回的权限继续保持收回。");
            } catch(ApiException exception) { plan.issues.add(exception.getMessage()); }
        }
        plan.fingerprint=fingerprint(request);
        return plan;
    }

    private Plan deltaPlan(DeltaRequest request) {
        if(request==null) throw invalid("缺少批量权限请求");
        Targets targets=targets(request.userIds(),request.departmentIds());
        Set<String> additions=codes(request.grants()),removals=codes(request.revokes());
        if(additions.isEmpty() && removals.isEmpty()) throw invalid("请至少选择一项要开通或收回的权限");
        if(!Collections.disjoint(additions,removals)) throw invalid("同一权限不能同时开通和收回");
        Map<String,Permission> catalog=catalog();
        validateCodes(union(additions,removals),catalog,policy->true);
        Plan plan=new Plan();
        plan.notes.add("只增减已选权限；其余配置、模板关联及个人收回保持原样。一次提交全部成功或全部回滚。");
        for(UUID id:targets.departments) {
            try {
                requireDepartment(id); validateCodes(additions,catalog,GrantPolicy::departmentGrantable);
                var before=departments.getDepartmentPermissions(id);
                Set<String> external=departmentExternalAfterDelta(id,targets.departments,additions,removals);
                Set<String> blocked=new TreeSet<>(removals);blocked.retainAll(external);
                if(!blocked.isEmpty()) throw invalid(label("department",id)+"：所选收回权限仍由模板、上级部门或全员基础提供，请先调整该来源："+String.join("、",blocked));
                Set<String> manual=new TreeSet<>(before.permissions());manual.removeAll(removals);manual.addAll(additions);
                manual.addAll(PermissionDependencyGrantPlanner.additions(catalog.values(),additions,union(manual,external),removals,
                        permission->GrantPolicy.departmentGrantable(permission.grantPolicies()),"部门批量权限"));
                TargetPlan target=new TargetPlan("department",id,manual,Set.of(),union(manual,external),null);
                plan.targets.add(target);addChange(plan,target,union(before.permissions(),external),target.effective,catalog);
            } catch(ApiException exception) { plan.issues.add(exception.getMessage()); }
        }
        for(UUID id:targets.users) {
            try {
                UserAccount account=eligibleUser(id);validateCodes(additions,catalog,GrantPolicy::individuallyGrantable);
                var before=resolver.breakdownOf(account);
                Set<String> inherited=inheritedFor(account,plan);inherited.addAll(before.templatePermissions());
                if(targets.departments.isEmpty()) inherited.addAll(before.managerGrants());
                Set<String> grants=new TreeSet<>(before.grants()),revokes=new TreeSet<>(before.revokes());
                revokes.removeAll(additions);grants.addAll(additions);grants.removeAll(removals);revokes.addAll(removals);
                Set<String> available=union(inherited,grants);available.removeAll(revokes);
                grants.addAll(PermissionDependencyGrantPlanner.additions(catalog.values(),additions,available,revokes,
                        permission->GrantPolicy.individuallyGrantable(permission.grantPolicies()),"员工批量权限"));
                Set<String> effective=union(inherited,grants);effective.removeAll(revokes);
                effective=new TreeSet<>(new PermissionDependencyCatalog(catalog.values()).usablePermissions(effective));
                TargetPlan target=new TargetPlan("user",id,grants,revokes,effective,null);
                plan.targets.add(target);addChange(plan,target,before.effective(),effective,catalog);
            } catch(ApiException exception) { plan.issues.add(exception.getMessage()); }
        }
        plan.fingerprint=fingerprint(request); return plan;
    }

    private Result write(Plan plan,String action) {
        tx.bind(); boolean changed=false; UUID actor=support.requireCurrentUser().getId();
        for(TargetPlan target:plan.targets) {
            if(target.templateId!=null) {
                boolean same=plan.existingBindings.stream().anyMatch(binding->binding.kind().equals(target.kind)
                        && binding.targetId().equals(target.id) && binding.templateId().equals(target.templateId) && !binding.legacySnapshot());
                bindings.bind(target.kind,target.id,target.templateId,actor);changed|=!same;
            }
            if(target.kind.equals("department")) {
                changed|=!departments.restoreExactDepartmentPermissions(target.id,List.copyOf(target.grants)).isEmpty();
            } else changed|=!overrides.applyTemplateSourceConfiguration(target.id,target.grants,target.revokes,true).isEmpty();
        }
        if(changed) for(TargetPlan target:plan.targets) {
            List<Change> changes=plan.changes.stream().filter(change->change.targetId().equals(target.id) && change.kind().equals(target.kind)).toList();
            audit.record(action,target.kind.equals("user")?"users":"departments",target.id.toString(),
                    changes.stream().flatMap(change->change.added().stream()).toList(),
                    changes.stream().flatMap(change->change.removed().stream()).toList(),
                    Map.of("previewFingerprint",plan.fingerprint,"templateId",target.templateId==null?"":target.templateId.toString(),"changes",changes));
        }
        return new Result(changed,List.copyOf(plan.changes));
    }

    private void addBindingChange(Plan plan,TargetPlan target,TemplateData template) {
        if(plan.existingBindings.stream().noneMatch(binding->binding.kind().equals(target.kind) && binding.targetId().equals(target.id)
                && binding.templateId().equals(template.id) && !binding.legacySnapshot())) {
            plan.changes.add(new Change(target.kind,template.id.toString(),target.id,label(target.kind,target.id)+"：模板关联",List.of(template.name),List.of()));
        }
    }
    private void addChange(Plan plan,TargetPlan target,Collection<String> before,Collection<String> after,Map<String,Permission> catalog) {
        List<String> added=List.copyOf(difference(after,before));
        plan.changes.add(new Change(target.kind,target.templateId==null?"":target.templateId.toString(),target.id,label(target.kind,target.id),added,List.copyOf(difference(before,after))));
        for(String code:added) {
            Permission permission=catalog.get(code);
            if(permission!=null && !GrantPolicy.bulkEligible(permission.grantPolicies())) {
                String key=target.kind+":"+target.id+":"+code;
                plan.sensitive.add(new SensitiveAddition(key,permission.getName(),code,label(target.kind,target.id)));
            }
        }
    }
    private Set<String> departmentExternalAfterDelta(UUID id,Set<UUID> selected,Set<String> additions,Set<String> removals) {
        Set<String> result=union(permissions.findBaselineCodes(),permissions.findDepartmentTemplateCodes(id));
        @SuppressWarnings("unchecked") List<UUID> ancestors=em.createNativeQuery("""
                WITH RECURSIVE ancestors AS (
                    SELECT parent_id AS id FROM departments WHERE id=:id AND parent_id IS NOT NULL
                    UNION SELECT department.parent_id FROM departments department JOIN ancestors child ON department.id=child.id
                    WHERE department.parent_id IS NOT NULL
                ) SELECT id FROM ancestors
                """).setParameter("id",id).getResultList();
        for(UUID ancestor:ancestors) {
            Set<String> manual=new TreeSet<>(departmentPermissions.findPermissionCodesByDepartmentId(ancestor));
            if(selected.contains(ancestor)) { manual.removeAll(removals);manual.addAll(additions); }
            result.addAll(manual);result.addAll(permissions.findDepartmentTemplateCodes(ancestor));
        }
        return result;
    }

    private Set<String> inheritedFor(UserAccount account,Plan plan) {
        Set<String> result=new TreeSet<>(permissions.findBaselineCodes());
        @SuppressWarnings("unchecked") List<UUID> ancestors=em.createNativeQuery("""
                WITH RECURSIVE ancestors AS (
                    SELECT id,parent_id FROM departments WHERE id IN (
                        SELECT department_id FROM employees WHERE id=:id
                        UNION SELECT department_id FROM employee_secondary_departments WHERE employee_id=:id)
                    UNION SELECT parent.id,parent.parent_id FROM departments parent JOIN ancestors child ON parent.id=child.parent_id
                ) SELECT id FROM ancestors
                """).setParameter("id",account.getEmployeeId()).getResultList();
        for(UUID department:ancestors) {
            var replacement=plan.targets.stream().filter(target->target.kind.equals("department") && target.id.equals(department)).findFirst();
            if(replacement.isPresent()) result.addAll(replacement.get().effective);
            else { result.addAll(departmentPermissions.findPermissionCodesByDepartmentId(department));result.addAll(permissions.findDepartmentTemplateCodes(department)); }
        }
        return result;
    }
    private UserAccount eligibleUser(UUID id) {
        UserAccount account=support.require(id);support.requireAuthorizationTarget(account);
        Object[] employee=rows("SELECT status,is_deleted FROM employees WHERE id=:id",account.getEmployeeId()).stream().findFirst().orElse(null);
        if(!"active".equals(account.getStatus()) || employee==null || Boolean.TRUE.equals(employee[1])
                || !CurrentEmployeeStatusPolicy.isCurrentEmployee(employee[0].toString())) throw invalid("目标员工已离职、档案无效或账号未启用："+id);
        return account;
    }
    private void requireDepartment(UUID id) { if(rows("SELECT id,name FROM departments WHERE id=:id AND NOT is_deleted",id).isEmpty()) throw invalid("部门已删除或不存在："+id); }
    private String label(String kind,UUID id) {
        List<Object[]> rows=rows(kind.equals("department")?"SELECT code,name FROM departments WHERE id=:id":"SELECT e.code,e.full_name FROM employees e JOIN users u ON u.employee_id=e.id WHERE u.id=:id",id);
        return rows.isEmpty()?id.toString():rows.getFirst()[0]+" "+rows.getFirst()[1];
    }
    private TemplateData template(UUID id,long expected) {
        List<Object[]> rows=rows("SELECT id,name,permission_codes::text,row_version FROM permission_templates WHERE id=:id AND NOT is_deleted",id);
        if(rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND,"权限模板已删除或不存在");
        Object[] row=rows.getFirst(); if(((Number)row[3]).longValue()!=expected) throw conflict("模板已修改，请刷新后重新预览");
        try { return new TemplateData(id,row[1].toString(),new TreeSet<>(mapper.readValue(row[2].toString(),new com.fasterxml.jackson.core.type.TypeReference<List<String>>(){}))); }
        catch(java.io.IOException exception) { throw new IllegalStateException(exception); }
    }
    @SuppressWarnings("unchecked") private List<Object[]> rows(String sql,UUID id) { return em.createNativeQuery(sql).setParameter("id",id).getResultList(); }
    private Map<String,Permission> catalog() { return permissions.findAll().stream().collect(Collectors.toMap(Permission::getCode,permission->permission)); }
    private void validateCodes(Collection<String> codes,Map<String,Permission> catalog,java.util.function.Predicate<Set<GrantPolicy>> allowed) {
        for(String code:codes) { Permission permission=catalog.get(code);if(permission==null || !allowed.test(permission.grantPolicies())) throw invalid("此入口不能授予该权限或权限已不存在："+code); }
    }
    private Set<String> codes(List<String> requested) {
        if(requested==null) return new TreeSet<>();
        if(requested.size()>3000 || requested.stream().anyMatch(code->code==null || code.isBlank() || code.length()>256)) throw invalid("权限列表无效或超过上限");
        return new TreeSet<>(requested);
    }
    private Targets targets(List<UUID> users,List<UUID> departments) {
        List<UUID> u=users==null?List.of():users,d=departments==null?List.of():departments;
        if(u.size()+d.size()<1 || u.size()+d.size()>500 || u.stream().anyMatch(Objects::isNull) || d.stream().anyMatch(Objects::isNull)
                || new HashSet<>(u).size()!=u.size() || new HashSet<>(d).size()!=d.size()) throw invalid("请选择 1 至 500 个不重复的员工或部门");
        return new Targets(new TreeSet<>(u),new TreeSet<>(d));
    }
    private String fingerprint(Object request) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(mapper.writeValueAsBytes(List.of(request,transfer.stateFingerprint())))); }
        catch(Exception exception) { throw new IllegalStateException(exception); }
    }
    private void confirm(Plan plan,String expected,List<String> confirmations) {
        if(expected==null || !MessageDigest.isEqual(plan.fingerprint.getBytes(StandardCharsets.UTF_8),expected.getBytes(StandardCharsets.UTF_8))) throw conflict("配置、模板或所选对象已变化，请重新预览");
        if(!plan.issues.isEmpty()) throw invalid(String.join("；",plan.issues));
        if(!new HashSet<>(confirmations==null?List.of():confirmations).containsAll(plan.sensitive.stream().map(SensitiveAddition::key).toList())) throw invalid("请逐项确认本次新增的敏感权限");
    }
    @SafeVarargs private static Set<String> union(Collection<String>... sets) { Set<String> result=new TreeSet<>();for(var set:sets) result.addAll(set);return result; }
    private static Set<String> difference(Collection<String> left,Collection<String> right) { Set<String> result=new TreeSet<>(left);result.removeAll(right);return result; }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED,message); }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
    private record Targets(Set<UUID> users,Set<UUID> departments) {}
    private record TemplateData(UUID id,String name,Set<String> codes) {}
    private record TargetPlan(String kind,UUID id,Set<String> grants,Set<String> revokes,Set<String> effective,UUID templateId) {}
    private static final class Plan {
        UUID templateId;String fingerprint;List<Binding> existingBindings=List.of();
        final List<TargetPlan> targets=new ArrayList<>(); final List<String> issues=new ArrayList<>(),notes=new ArrayList<>();
        final List<Change> changes=new ArrayList<>();final List<SensitiveAddition> sensitive=new ArrayList<>();
        Preview preview() { return new Preview(fingerprint,issues.isEmpty(),List.copyOf(issues),List.copyOf(changes),List.copyOf(sensitive),List.of(),List.of(),List.copyOf(notes)); }
    }
}
