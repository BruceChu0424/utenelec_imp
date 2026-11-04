package com.uten.imp.features.approvalpolicy;

import com.uten.imp.application.port.ApprovalCandidateDirectoryPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Administrative routing assignments never grant the assignee any business permission. */
@Service
@RequiredArgsConstructor
public class DepartmentApprovalPolicyService {
    private final NamedParameterJdbcTemplate jdbc;
    private final ApprovalCandidateDirectoryPort candidates;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final AuditService audit;
    public record DepartmentPolicy(UUID departmentId,String departmentCode,String departmentName,UUID managerId,String managerName,
            UUID substituteEmployeeId,String substituteEmployeeName,long version){}
    public record Candidate(UUID id,String name,String employeeCode,UUID departmentId,String departmentName){}
    public record Update(UUID substituteEmployeeId,Long expectedVersion){}

    @Transactional(readOnly=true)
    public List<DepartmentPolicy> departments() {
        requireManager();return jdbc.query(ROWS+" WHERE NOT d.is_deleted AND d.level<>'公司' ORDER BY d.sort_order,d.code,d.id",Map.of(),(r,n)->row(r));
    }

    @Transactional(readOnly=true)
    public List<Candidate> candidates(UUID department,String search) {
        requireManager();var target=department(department);
        Set<UUID> ids=new LinkedHashSet<>();
        for(String permission:List.of("expense:approve:department","application:approve:department"))
            candidates.candidates(permission,Set.of("attachment:view","attachment:download")).forEach(candidate->ids.add(candidate.employeeId()));
        ids.remove(target.managerId());if(ids.isEmpty())return List.of();
        String keyword=search==null?"":search.trim();if(keyword.length()>200)throw new ApiException(ErrorCode.VALIDATION_FAILED,"搜索内容过长");
        return jdbc.query("""
            SELECT e.id,e.full_name,e.code,e.department_id,d.name FROM employees e LEFT JOIN departments d ON d.id=e.department_id
            WHERE e.id IN(:ids) AND NOT e.is_deleted AND (e.full_name ILIKE :search OR e.code ILIKE :search OR d.name ILIKE :search)
            ORDER BY e.full_name,e.code,e.id LIMIT 100
            """,Map.of("ids",ids,"search","%"+keyword+"%"),(r,n)->new Candidate(r.getObject(1,UUID.class),r.getString(2),r.getString(3),r.getObject(4,UUID.class),r.getString(5)));
    }

    @Transactional
    public DepartmentPolicy update(UUID department,Update input) {
        AuthUser actor=requireManager();
        if(input==null||input.expectedVersion()==null||input.expectedVersion()<0)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请刷新审批设置后重试");
        tx.bind();jdbc.queryForList("SELECT id FROM departments WHERE id=:id AND NOT is_deleted FOR UPDATE",Map.of("id",department),UUID.class);
        var before=department(department);if(before.version()!=input.expectedVersion())throw new ApiException(ErrorCode.CONFLICT,"审批设置已被更新，请刷新后重试");
        if(input.substituteEmployeeId()!=null) {
            if(input.substituteEmployeeId().equals(before.managerId()))throw new ApiException(ErrorCode.VALIDATION_FAILED,"负责人不能作为自己的回避审批人");
            boolean eligible=false;
            for(String permission:List.of("expense:approve:department","application:approve:department"))
                if(candidates.candidates(permission,Set.of("attachment:view","attachment:download")).stream().anyMatch(c->input.substituteEmployeeId().equals(c.employeeId())))eligible=true;
            if(!eligible)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择在职且已获部门审核及原件查看下载权限的上级或替补；本设置不会代为授予权限");
        }
        if(Objects.equals(before.substituteEmployeeId(),input.substituteEmployeeId()))return before;
        if(actor.getEmployeeId()!=null&&actor.getEmployeeId().equals(before.managerId()))
            throw new ApiException(ErrorCode.FORBIDDEN,"不能为本人申请选择或清除回避审批人，请由另一名审批设置管理员配置");
        Map<String,Object> args=new HashMap<>();args.put("department",department);args.put("substitute",input.substituteEmployeeId());args.put("actor",actor.getId());args.put("version",input.expectedVersion());
        int changed=jdbc.update("""
            INSERT INTO department_approval_policies(department_id,substitute_employee_id,version,created_by,updated_by)
            VALUES(:department,:substitute,1,:actor,:actor)
            ON CONFLICT(department_id) DO UPDATE SET substitute_employee_id=excluded.substitute_employee_id,
                version=department_approval_policies.version+1,updated_at=now(),updated_by=:actor
            WHERE department_approval_policies.version=:version
            """,args);
        if(changed!=1)throw new ApiException(ErrorCode.CONFLICT,"审批设置已被更新，请刷新后重试");
        audit.logCommitted(actor.getId(),actor.getUsername(),"configure_department_approval_substitute","department_approval_policies",department.toString(),"success");
        return department(department);
    }

    private AuthUser requireManager() {
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(actor.isVisitor()||actor.getId()==null||!actor.getPermissions().contains("approval_policy:manage"))throw new ApiException(ErrorCode.FORBIDDEN);
        return actor;
    }
    private DepartmentPolicy department(UUID id) {
        return jdbc.query(ROWS+" WHERE d.id=:id AND NOT d.is_deleted AND d.level<>'公司'",Map.of("id",id),(r,n)->row(r)).stream().findFirst()
                .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"部门不存在"));
    }
    private static DepartmentPolicy row(java.sql.ResultSet row)throws java.sql.SQLException {
        return new DepartmentPolicy(row.getObject(1,UUID.class),row.getString(2),row.getString(3),row.getObject(4,UUID.class),row.getString(5),row.getObject(6,UUID.class),row.getString(7),row.getLong(8));
    }
    private static final String ROWS="""
        SELECT d.id,d.code,d.name,d.manager_id,m.full_name,p.substitute_employee_id,s.full_name,COALESCE(p.version,0)
        FROM departments d LEFT JOIN employees m ON m.id=d.manager_id
        LEFT JOIN department_approval_policies p ON p.department_id=d.id
        LEFT JOIN employees s ON s.id=p.substitute_employee_id
        """;
}
