package com.uten.imp.application.policy;

import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.*;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Shared department approval scope for expense and administrative workflows. */
@Component
@RequiredArgsConstructor
public class DepartmentApprovalScope {
    private final JdbcTemplate jdbc;
    public record Scope(Set<UUID> departmentIds,Map<UUID,String> departmentCodes){}
    public boolean isCurrent(AuthUser user){
        if(user==null||user.isVisitor()||user.getEmployeeId()==null)return false;
        Object key=List.of(this,"current",user.getEmployeeId());
        if(TransactionSynchronizationManager.hasResource(key))return (Boolean)TransactionSynchronizationManager.getResource(key);
        boolean value=Boolean.TRUE.equals(new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(jdbc).queryForObject(
            "SELECT EXISTS(SELECT 1 FROM employees WHERE id=:id AND NOT is_deleted AND status IN(:statuses))",
            Map.of("id",user.getEmployeeId(),"statuses",com.uten.imp.common.identity.CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES),Boolean.class));
        cache(key,value);return value;
    }
    private void cache(Object key,Object value){if(TransactionSynchronizationManager.isSynchronizationActive()){
        TransactionSynchronizationManager.bindResource(key,value);
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization(){
            @Override public void afterCompletion(int status){TransactionSynchronizationManager.unbindResourceIfPossible(key);}
        });
    }}
    public Scope load(AuthUser user) {
        Set<UUID> ids=new LinkedHashSet<>();Map<UUID,String> codes=new LinkedHashMap<>();
        if(!isCurrent(user))return new Scope(Set.of(),Map.of());
        Object key=List.of(this,"scope",user.getEmployeeId(),user.isSuperAdmin());
        if(TransactionSynchronizationManager.hasResource(key))return (Scope)TransactionSynchronizationManager.getResource(key);
        jdbc.query("""
          WITH RECURSIVE roots(id) AS (
            SELECT d.id FROM departments d WHERE NOT d.is_deleted AND
              (? OR d.manager_id=? OR d.id=(SELECT department_id FROM employees WHERE id=? AND NOT is_deleted)
               OR d.id IN(SELECT department_id FROM employee_secondary_departments WHERE employee_id=?))
          ), scoped(id) AS (
            SELECT id FROM roots UNION SELECT d.id FROM departments d JOIN scoped p ON d.parent_id=p.id WHERE NOT d.is_deleted
          ), ancestry(id,parent_id,code,level,depth) AS (
            SELECT d.id,d.parent_id,d.code,d.level,0 FROM departments d JOIN scoped s ON s.id=d.id
            UNION ALL SELECT a.id,p.parent_id,p.code,p.level,a.depth+1 FROM ancestry a
              JOIN departments p ON p.id=a.parent_id WHERE NOT p.is_deleted
          ) SELECT DISTINCT ON(id) id,code FROM ancestry
          ORDER BY id,CASE WHEN level='一级部门' OR code='GM' THEN 0 ELSE 1 END,depth DESC
          """, row->{UUID id=row.getObject(1,UUID.class);ids.add(id);codes.put(id,row.getString(2));},
          user.isSuperAdmin(),user.getEmployeeId(),user.getEmployeeId(),user.getEmployeeId());
        var result=new Scope(Set.copyOf(ids),Map.copyOf(codes));cache(key,result);return result;
    }
}
