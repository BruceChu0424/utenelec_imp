package com.uten.imp.features.finance.application;
import com.uten.imp.security.AuthUser;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.*;

/** One object predicate for application lists/details, native links, evidence and task-lease names. */
@Component @RequiredArgsConstructor
public class FinanceApplicationReadAccess {
    private final JdbcTemplate db;
    record Predicate(String sql,List<Object> arguments) { }
    Predicate predicate(String alias,AuthUser actor){
        if(!alias.matches("[a-z][a-z0-9_]*"))throw new IllegalArgumentException("Internal SQL alias");
        if(actor==null||actor.isVisitor()||actor.getEmployeeId()==null)return new Predicate("false",List.of());
        boolean view=actor.getPermissions().contains(FinanceApplicationPermissions.VIEW),operational=actor.getPermissions().stream().anyMatch(Set.of(FinanceApplicationPermissions.EXECUTE,FinanceApplicationPermissions.CONFIRM,FinanceApplicationPermissions.REVERSE)::contains);
        String sql="(? OR fn_canonical_employee_identity("+alias+".applicant_id)=fn_canonical_employee_identity(?) OR (? AND (EXISTS(SELECT 1 FROM finance_application_nodes n CROSS JOIN LATERAL jsonb_array_elements(n.assignees) person WHERE n.application_id="+alias+".id AND fn_canonical_employee_identity((person->>'employeeId')::uuid)=fn_canonical_employee_identity(?)) OR (? AND "+alias+".status IN('APPROVED','EXECUTED','CONFIRMED','REVERSED')))))";
        return new Predicate(sql,List.of(actor.isSuperAdmin(),actor.getEmployeeId(),view,actor.getEmployeeId(),operational));
    }
    public Set<UUID> readableIds(Collection<UUID> ids,AuthUser actor){if(ids.isEmpty())return Set.of();var condition=predicate("a",actor);var values=ids.stream().filter(Objects::nonNull).distinct().toList();Set<UUID> result=new HashSet<>();for(int from=0;from<values.size();from+=1000){var part=values.subList(from,Math.min(values.size(),from+1000));List<Object>args=new ArrayList<>(part);args.addAll(condition.arguments());result.addAll(db.queryForList("SELECT a.id FROM finance_applications a WHERE a.id IN("+String.join(",",Collections.nCopies(part.size(),"?"))+") AND "+condition.sql(),UUID.class,args.toArray()));}return Set.copyOf(result);}
    public void require(UUID id,AuthUser actor){if(id==null||!readableIds(List.of(id),actor).contains(id))throw new ApiException(ErrorCode.NOT_FOUND,"原申请不存在或不在明确参与范围内");}
}
