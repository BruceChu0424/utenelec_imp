package com.uten.imp.features.admin;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionTemplateDtos.*;
import com.uten.imp.features.admin.dto.PermissionTransferDtos.*;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class PermissionTemplateService {
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final PermissionConfigurationTransferService transfer;
    private final PermissionRepository permissions;
    private final AdminUserSupport support;
    private final PermissionChangeAudit audit;
    private final PermissionTemplateBindingService bindings;
    private final TxSessionVars tx;
    private final PermissionTemplateAssignmentService assignments;

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public List<Template> list() {
        transfer.requireActor();
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("SELECT id,name,description,permission_codes::text,row_version,updated_at::text FROM permission_templates WHERE NOT is_deleted ORDER BY lower(name),id").getResultList();
        Map<UUID,List<Binding>> assigned=bindings.list().stream().collect(Collectors.groupingBy(Binding::templateId));
        return rows.stream().map(row -> decode(row,assigned.getOrDefault(idOf(row),List.of()))).toList();
    }
    @Transactional public Template create(Save request) { return save(UUID.randomUUID(),request,true); }
    @Transactional public Template update(UUID id,Save request) { return save(id,request,false); }

    private Template save(UUID id,Save request,boolean create) {
        transfer.lockConfiguration(); transfer.requireActor(); tx.bind();
        if(request==null || request.expectedVersion()==null || request.expectedVersion()<0) throw invalid("缺少模板版本，请刷新后重试");
        Template previous=create?null:require(id,request.expectedVersion(),true);
        if(create && request.expectedVersion()!=0) throw conflict();
        String name=request.name()==null?"":request.name().trim();
        String description=request.description()==null?"":request.description().trim();
        if(name.isBlank() || name.length()>80 || description.length()>1000) throw invalid("模板名称为 1 至 80 字，说明不超过 1000 字");
        Set<String> codes=validate(request.permissions());
        if(!create) assignments.validateLinkedDepartments(id,codes);
        long same=((Number)em.createNativeQuery("SELECT count(*) FROM permission_templates WHERE NOT is_deleted AND lower(btrim(name))=lower(:name) AND id<>:id")
                .setParameter("name",name).setParameter("id",id).getSingleResult()).longValue();
        if(same>0) throw invalid("已存在同名权限模板，请使用其他名称");
        if(create && ((Number)em.createNativeQuery("SELECT count(*) FROM permission_templates WHERE NOT is_deleted").getSingleResult()).longValue()>=1000) throw invalid("权限模板最多保存 1000 个，请先删除不再使用的模板");
        if(previous!=null && name.equals(previous.name()) && description.equals(previous.description()) && codes.equals(new TreeSet<>(previous.permissions()))) return previous;
        if(previous!=null && bindings.list().stream().anyMatch(binding->binding.templateId().equals(id) && !binding.legacySnapshot())) {
            Set<String> confirmed=new HashSet<>(request.sensitiveConfirmations()==null?List.of():request.sensitiveConfirmations());
            Set<String> added=new TreeSet<>(codes);added.removeAll(previous.permissions());
            Map<String,Permission> catalog=permissions.findAll().stream().collect(Collectors.toMap(Permission::getCode,permission->permission));
            for(String code:added) if(!GrantPolicy.bulkEligible(catalog.get(code).grantPolicies()) && !confirmed.contains(code)) {
                throw invalid("模板已有关联对象，请逐项确认本次新增的敏感权限："+catalog.get(code).getName());
            }
        }
        UUID actor=support.requireCurrentUser().getId();
        if(create) em.createNativeQuery("INSERT INTO permission_templates(id,name,description,permission_codes,created_by,updated_by) VALUES (:id,:name,:description,CAST(:codes AS jsonb),:actor,:actor)")
                .setParameter("id",id).setParameter("name",name).setParameter("description",description).setParameter("codes",encode(codes)).setParameter("actor",actor).executeUpdate();
        else em.createNativeQuery("UPDATE permission_templates SET name=:name,description=:description,permission_codes=CAST(:codes AS jsonb),row_version=row_version+1,updated_by=:actor,updated_at=now() WHERE id=:id")
                .setParameter("id",id).setParameter("name",name).setParameter("description",description).setParameter("codes",encode(codes)).setParameter("actor",actor).executeUpdate();
        Set<String> before=previous==null?Set.of():new TreeSet<>(previous.permissions());
        audit.record(create?"permission_template_create":"permission_template_update","permission_templates",id.toString(),difference(codes,before),difference(before,codes),
                Map.of("name",name,"description",description,"version",create?0:previous.version()+1));
        // 模板修改后差量同步到全部绑定账号（个人收回优先，2026-10-27 用户口径）。
        if(previous!=null && !before.equals(codes)) {
            var linked=bindings.list().stream().filter(binding->binding.templateId().equals(id) && !binding.legacySnapshot()).toList();
            if(!linked.isEmpty()) audit.record("permission_template_sync","permission_templates",id.toString(),
                    difference(codes,before),difference(before,codes),Map.of("targets",linked,"source","independent_live_template"));
        }
        return require(id,null,false);
    }

    @Transactional public void delete(UUID id,Delete request) {
        transfer.lockConfiguration(); transfer.requireActor(); tx.bind();
        if(request==null || request.expectedVersion()==null) throw invalid("缺少模板版本");
        Template previous=require(id,request.expectedVersion(),true);
        assignments.detachTemplate(id);
        em.createNativeQuery("UPDATE permission_templates SET is_deleted=true,row_version=row_version+1,updated_by=:actor,updated_at=now() WHERE id=:id")
                .setParameter("id",id).setParameter("actor",support.requireCurrentUser().getId()).executeUpdate();
        // 删除模板解除关联：已应用账号保持当前权限，仅不再跟随后续变更（本模板也已不可再改）。
        audit.record("permission_template_delete","permission_templates",id.toString(),List.of(),previous.permissions(),Map.of("name",previous.name(),"version",previous.version()+1));
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Preview preview(UUID targetId,Apply request) {
        validateApply(request);
        return assignments.preview(new BatchApply(request.templateId(),request.templateVersion(),request.mode(),List.of(targetId),List.of()));
    }

    @Transactional public Result apply(UUID targetId,Commit commit) {
        if(commit==null) throw invalid("缺少模板应用请求");
        Apply request=commit.request();validateApply(request);
        return assignments.apply(new BatchCommit(new BatchApply(request.templateId(),request.templateVersion(),request.mode(),List.of(targetId),List.of()),
                commit.expectedFingerprint(),commit.sensitiveConfirmations()));
    }

    private void validateApply(Apply request) {
        if(request==null || request.templateId()==null || request.templateVersion()==null || request.templateVersion()<0 || request.mode()==null) throw invalid("请选择模板、版本和应用方式");
    }
    private Template require(UUID id,Long expected,boolean lock) {
        List<Object[]> rows;
        try {
            @SuppressWarnings("unchecked") List<Object[]> loaded=em.createNativeQuery("SELECT id,name,description,permission_codes::text,row_version,updated_at::text FROM permission_templates WHERE id=:id AND NOT is_deleted"+(lock?" FOR UPDATE NOWAIT":""))
                    .setParameter("id",id).getResultList();
            rows=loaded;
        } catch(RuntimeException exception) {
            if(lock) throw conflict();
            throw exception;
        }
        if(rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND,"权限模板已删除或不存在，请刷新模板列表");
        Template template=decode(rows.getFirst(),bindings.list().stream().filter(binding->binding.templateId().equals(id)).toList());
        if(expected!=null && template.version()!=expected) throw conflict();
        return template;
    }
    private static UUID idOf(Object[] row) { return (UUID) row[0]; }
    private Template decode(Object[] row,List<Binding> assigned) {
        try { return new Template((UUID)row[0],row[1].toString(),row[2].toString(),mapper.readValue(row[3].toString(),new TypeReference<List<String>>(){}),((Number)row[4]).longValue(),row[5].toString(),assigned.size(),
                    assigned.stream().filter(binding->binding.kind().equals("user")).count(),
                    assigned.stream().filter(binding->binding.kind().equals("department")).count()); }
        catch(Exception exception) { throw new IllegalStateException("Invalid permission template storage",exception); }
    }
    private Set<String> validate(List<String> requested) {
        if(requested==null || requested.size()>3000 || requested.stream().anyMatch(code->code==null || code.isBlank() || code.length()>256)) throw invalid("模板权限列表无效或超过上限");
        Set<String> codes=new TreeSet<>(requested);
        Map<String,Permission> catalog=permissions.findAll().stream().collect(Collectors.toMap(Permission::getCode,p->p));
        for(String code:codes) if(!catalog.containsKey(code) || !GrantPolicy.individuallyGrantable(catalog.get(code).grantPolicies())) throw invalid("模板不能包含不存在或仅限超级管理员的权限："+code);
        if(!new PermissionDependencyCatalog(catalog.values()).usablePermissions(codes).equals(codes)) throw invalid("模板缺少操作必需的查看权限，请核对权限依赖后保存");
        return codes;
    }
    private String encode(Collection<String> codes) { try {return mapper.writeValueAsString(codes);} catch(Exception exception){throw new IllegalStateException(exception);} }
    private static List<String> difference(Collection<String> a,Collection<String> b){var result=new TreeSet<>(a);result.removeAll(b);return List.copyOf(result);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(){return new ApiException(ErrorCode.CONFLICT,"权限模板已被其他管理员修改，请刷新后重新预览");}
}
