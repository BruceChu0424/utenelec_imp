package com.uten.imp.application.policy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.util.*;

/** The only department/recusal routing rule used by applications, reimbursements, queues and notices. */
@Component
@RequiredArgsConstructor
public class DepartmentApprovalRouting {
    private final NamedParameterJdbcTemplate jdbc;
    private final DepartmentApprovalScope departments;
    private final ObjectMapper json;
    private record Configuration(UUID department,UUID manager,long generation,UUID substitute,long version,String code){}
    private record Scope(Set<UUID> ordinary,Map<UUID,Configuration> configurations){}

    public String capture(UUID applicantId,UUID departmentId) {
        lock(departmentId);
        var rows=jdbc.query("""
            SELECT d.id,d.manager_id,d.permission_delegation_generation,p.substitute_employee_id,COALESCE(p.version,0),d.code
            FROM departments d LEFT JOIN department_approval_policies p ON p.department_id=d.id WHERE d.id=:id AND NOT d.is_deleted
            """,Map.of("id",departmentId), (r,n)->configuration(r));
        if(rows.isEmpty())throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"申请部门已变更，请核对部门后重新保存");
        var c=rows.getFirst();
        if(applicantId.equals(c.manager())&&c.substitute()==null)throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"负责人本人申请须预先配置本部门回避审批人，请联系审批设置管理员");
        var snapshot=json.createObjectNode();
        snapshot.put("departmentId",departmentId.toString());snapshot.put("requiresSubstitute",applicantId.equals(c.manager()));
        snapshot.put("managerId",c.manager()==null?null:c.manager().toString());snapshot.put("departmentGeneration",c.generation());
        snapshot.put("configurationVersion",c.version());snapshot.put("substituteEmployeeId",c.substitute()==null?null:c.substitute().toString());
        return snapshot.toString();
    }

    public boolean canReview(AuthUser actor,UUID applicantId,UUID departmentId,String snapshot) {
        if(actor==null||actor.getEmployeeId()==null||actor.getEmployeeId().equals(applicantId)||departmentId==null||!departments.isCurrent(actor))return false;
        var scope=scope(businessActor(actor));var c=scope.configurations().get(departmentId);if(c==null)return false;
        try {
            var facts=snapshot==null?json.createObjectNode():json.readTree(snapshot);
            if(facts.path("requiresSubstitute").asBoolean(false))return departmentId.toString().equals(facts.path("departmentId").asText())
                && applicantId.equals(c.manager()) && applicantId.toString().equals(facts.path("managerId").asText())
                && c.generation()==facts.path("departmentGeneration").asLong(-1) && c.version()==facts.path("configurationVersion").asLong(-1)
                && actor.getEmployeeId().equals(c.substitute()) && actor.getEmployeeId().toString().equals(facts.path("substituteEmployeeId").asText());
            return !applicantId.equals(c.manager())&&scope.ordinary().contains(departmentId);
        } catch(com.fasterxml.jackson.core.JsonProcessingException invalid){return false;}
    }

    /** The alias is server-owned SQL, never a request value. */
    public String sql(String alias,AuthUser actor) {
        return sql(alias+".applicant_id",alias+".applicant_department_id",alias+".department_approval_snapshot",actor);
    }

    public String sql(String applicantExpression,String departmentExpression,String snapshotExpression,AuthUser actor) {
        if(actor==null||actor.getEmployeeId()==null)return "FALSE";
        return "fn_department_approval_can_review('"+actor.getEmployeeId()+"'::uuid,"+applicantExpression+","+departmentExpression+","+snapshotExpression+")";
    }

    public Map<UUID,String> departmentCodes(AuthUser actor) {
        if(actor==null||actor.getEmployeeId()==null||!departments.isCurrent(actor))return Map.of();
        actor=businessActor(actor);
        var scope=scope(actor);Map<UUID,String> codes=new LinkedHashMap<>(departments.load(actor).departmentCodes());
        for(var c:scope.configurations().values())if(actor.getEmployeeId().equals(c.substitute()))codes.put(c.department(),c.code());
        return Map.copyOf(codes);
    }

    public void requireReviewForUpdate(AuthUser actor,UUID applicant,UUID department,String snapshot) {
        if(actor==null||actor.getEmployeeId()==null)throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN);
        lock(department);
        Map<String,Object> args=new HashMap<>();args.put("actor",actor.getEmployeeId());args.put("applicant",applicant);args.put("department",department);args.put("snapshot",snapshot);
        if(!Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_department_approval_can_review(:actor,:applicant,:department,CAST(:snapshot AS jsonb))",args,Boolean.class)))
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"当前部门或回避审批配置已变化，请刷新后重新核对；配置已变化的申请须撤回重提");
    }

    private void lock(UUID department) {
        jdbc.queryForList("SELECT id FROM departments WHERE id=:id FOR SHARE",Map.of("id",department),UUID.class);
        jdbc.queryForList("SELECT id FROM department_approval_policies WHERE department_id=:id FOR SHARE",Map.of("id",department),UUID.class);
    }

    private static AuthUser businessActor(AuthUser actor) {
        return !actor.isSuperAdmin()?actor:new AuthUser(actor.getId(),actor.getEmployeeId(),actor.getLoginAccount(),actor.getPermissions(),actor.isMustChangePassword(),actor.isAccountNonLocked(),false,actor.isRemoteAccess(),actor.getImpersonatedBy(),actor.getSessionId());
    }

    public boolean isStale(UUID applicantId,UUID departmentId,String snapshot) {
        if(applicantId==null||departmentId==null)return true;
        var c=configuration(departmentId);if(c==null)return true;
        try {
            var facts=snapshot==null?json.createObjectNode():json.readTree(snapshot);
            if(!facts.path("requiresSubstitute").asBoolean(false))return applicantId.equals(c.manager());
            return !departmentId.toString().equals(facts.path("departmentId").asText())||!applicantId.equals(c.manager())
                ||!applicantId.toString().equals(facts.path("managerId").asText())||c.generation()!=facts.path("departmentGeneration").asLong(-1)
                ||c.version()!=facts.path("configurationVersion").asLong(-1)||c.substitute()==null||!c.substitute().toString().equals(facts.path("substituteEmployeeId").asText());
        } catch(com.fasterxml.jackson.core.JsonProcessingException invalid){return true;}
    }

    @SuppressWarnings("unchecked")
    private Configuration configuration(UUID id) {
        var key=List.of(this,"configuration",id);
        if(TransactionSynchronizationManager.hasResource(key))return ((java.util.Optional<Configuration>)TransactionSynchronizationManager.getResource(key)).orElse(null);
        var result=jdbc.query("SELECT d.id,d.manager_id,d.permission_delegation_generation,p.substitute_employee_id,COALESCE(p.version,0),d.code FROM departments d LEFT JOIN department_approval_policies p ON p.department_id=d.id WHERE d.id=:id AND NOT d.is_deleted",Map.of("id",id),(r,n)->configuration(r)).stream().findFirst();
        if(TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.bindResource(key,result);
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization(){@Override public void afterCompletion(int status){TransactionSynchronizationManager.unbindResourceIfPossible(key);}});
        }
        return result.orElse(null);
    }

    private Scope scope(AuthUser actor) {
        var key=List.of(this,actor.getId(),actor.getEmployeeId(),actor.isSuperAdmin());
        if(TransactionSynchronizationManager.hasResource(key))return (Scope)TransactionSynchronizationManager.getResource(key);
        var ordinary=departments.load(actor);Set<UUID> ids=ordinary.departmentIds();
        var args=new HashMap<String,Object>();args.put("actor",actor.getEmployeeId());args.put("ids",ids.isEmpty()?Set.of(new UUID(0,0)):ids);
        var rows=jdbc.query("""
            SELECT d.id,d.manager_id,d.permission_delegation_generation,p.substitute_employee_id,COALESCE(p.version,0),fn_department_approval_workbench_code(d.id)
            FROM departments d LEFT JOIN department_approval_policies p ON p.department_id=d.id
            WHERE NOT d.is_deleted AND (d.id IN(:ids) OR p.substitute_employee_id=:actor)
            """,args,(r,n)->configuration(r));
        Map<UUID,Configuration> map=new LinkedHashMap<>();rows.forEach(c->map.put(c.department(),c));var result=new Scope(ids,Map.copyOf(map));
        if(TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.bindResource(key,result);
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization(){@Override public void afterCompletion(int status){TransactionSynchronizationManager.unbindResourceIfPossible(key);}});
        }
        return result;
    }
    private static Configuration configuration(java.sql.ResultSet row)throws java.sql.SQLException {
        return new Configuration(row.getObject(1,UUID.class),row.getObject(2,UUID.class),row.getLong(3),row.getObject(4,UUID.class),row.getLong(5),row.getString(6));
    }
}
