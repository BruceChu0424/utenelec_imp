package com.uten.imp.features.finance.application;

import com.uten.imp.common.web.*;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.finance.application.FinanceApplicationContracts.*;

/** Explicit assignment, current operating authority and one settings lock; no nickname matching. */
@Service @RequiredArgsConstructor
public class FinanceApplicationRoles {
    private final JdbcTemplate db;private final UserAccountRepository users;private final PermissionResolver permissions;
    private final SecurityContextCurrentUser current;private final TxSessionVars tx;
    void lockSettings(){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-application-settings',0))",rs->{});}
    AuthUser staff(){var user=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));if(user.isVisitor()||user.getEmployeeId()==null)throw new ApiException(ErrorCode.FORBIDDEN,"申请流程仅限有效员工账号");return user;}
    boolean has(AuthUser user,String code){return user.isSuperAdmin()||user.getPermissions().contains(code);}
    AuthUser live(String action){
        var actor=staff();require(actor,FinanceApplicationPermissions.VIEW,action);
        int active=db.queryForObject("SELECT count(*) FROM users u JOIN employees e ON e.id=u.employee_id WHERE u.id=? AND NOT u.is_deleted AND u.status='active' AND NOT e.is_deleted AND e.status<>'resigned' AND e.id=fn_canonical_employee_identity(?)",Integer.class,current.requireId(),actor.getEmployeeId());
        var account=users.findById(current.requireId());if(active!=1||account.isEmpty()||(!actor.isSuperAdmin()&&!permissions.permsOf(account.get()).containsAll(Set.of(FinanceApplicationPermissions.VIEW,action))))throw new ApiException(ErrorCode.FORBIDDEN,"当前人员账号或申请处理权限已变化，请重新核对");return actor;
    }
    void require(AuthUser user,String...codes){for(String code:codes)if(!has(user,code))throw new ApiException(ErrorCode.FORBIDDEN,"缺少操作权限："+code);}
    @Transactional(readOnly=true)
    public Map<String,Object> settings(){var user=staff();require(user,FinanceApplicationPermissions.SETTINGS);
        var result=new LinkedHashMap<>(db.queryForMap("SELECT enabled,enabled_at AS \"enabledAt\",row_version AS version,source_reference AS \"sourceReference\" FROM finance_application_settings WHERE id=1"));
        result.put("roles",db.queryForList("""
                SELECT b.id,b.role_key AS "roleKey",b.department_id AS "departmentId",b.employee_id AS "employeeId",
                    COALESCE(e.full_name,'') AS "employeeName",COALESCE(d.name,'') AS "departmentName",b.row_version AS version,b.source_reference AS "sourceReference"
                FROM finance_application_role_bindings b LEFT JOIN employees e ON e.id=fn_canonical_employee_identity(b.employee_id)
                LEFT JOIN departments d ON d.id=b.department_id ORDER BY b.role_key,b.department_id NULLS FIRST,b.id
                """));result.put("roleDefinitions",java.util.Arrays.stream(FinanceApplicationCatalog.Role.values()).map(r->Map.of("key",r.name(),"label",FinanceApplicationCatalog.roleTitle(r))).toList());return result;
    }
    @Transactional
    public Map<String,Object> saveSettings(SettingsInput input){var user=staff();require(user,FinanceApplicationPermissions.SETTINGS);if(input==null)throw invalid("请核对设置");tx.bind();lockSettings();
        String reference=text(input.sourceReference(),1000,"启用/关闭依据");if(reference.strip().length()<8)throw invalid("请填写至少8字的流程启用/关闭依据");
        var old=db.queryForMap("SELECT enabled,row_version,source_reference FROM finance_application_settings WHERE id=1 FOR UPDATE");
        if(Objects.equals(old.get("enabled"),input.enabled())&&reference.equals(old.get("source_reference")))return settings();
        if(((Number)old.get("row_version")).longValue()!=input.expectedVersion())throw conflict("流程设置已变化，请刷新核对，原输入请保留");
        if(input.enabled())for(var role:FinanceApplicationCatalog.Role.values())if(role!=FinanceApplicationCatalog.Role.DEPARTMENT_REVIEW){
            var ids=db.queryForList("SELECT employee_id FROM finance_application_role_bindings WHERE role_key=? AND department_id IS NULL",UUID.class,role.name());
            if(ids.isEmpty())throw invalid("请先明确配置"+FinanceApplicationCatalog.roleTitle(role));for(UUID id:ids)eligible(id,true);
        }
        if(input.enabled()&&!Boolean.TRUE.equals(old.get("enabled")))db.update("INSERT INTO finance_application_enable_periods(enabled_at,actor_id,source_reference) VALUES(now(),?,?)",current.requireId(),reference);
        else if(!input.enabled())db.update("UPDATE finance_application_enable_periods SET disabled_at=now() WHERE disabled_at IS NULL");
        db.update("UPDATE finance_application_settings SET enabled=?,enabled_at=CASE WHEN ? THEN now() ELSE enabled_at END,source_reference=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=1",input.enabled(),input.enabled(),reference,current.requireId());return settings();
    }
    @Transactional
    public Map<String,Object> saveRole(RoleInput input){var user=staff();require(user,FinanceApplicationPermissions.SETTINGS);if(input==null||input.id()==null||input.employeeId()==null)throw invalid("请选择真实员工");
        FinanceApplicationCatalog.Role role;try{role=FinanceApplicationCatalog.Role.valueOf(input.roleKey());}catch(Exception e){throw invalid("原流程岗位不存在");}
        if(role==FinanceApplicationCatalog.Role.DEPARTMENT_REVIEW?input.departmentId()==null:input.departmentId()!=null)throw invalid("部门负责人代理需明确部门；其它原岗位按公司配置");
        var assignee=eligible(input.employeeId(),true);String reference=text(input.sourceReference(),1000,"指派依据");if(reference.strip().length()<4)throw invalid("请填写明确指派依据");
        tx.bind();lockSettings();if(input.departmentId()!=null&&db.queryForObject("SELECT count(*) FROM departments WHERE id=? AND NOT is_deleted",Integer.class,input.departmentId())!=1)throw invalid("部门不存在或已删除");
        var rows=db.queryForList("SELECT role_key,department_id,employee_id,source_reference,row_version FROM finance_application_role_bindings WHERE id=? FOR UPDATE",input.id());
        if(!rows.isEmpty()){var old=rows.getFirst();if(role.name().equals(old.get("role_key"))&&Objects.equals(input.departmentId(),old.get("department_id"))&&assignee.employeeId().equals(old.get("employee_id"))&&reference.equals(old.get("source_reference")))return settings();if(((Number)old.get("row_version")).longValue()!=input.expectedVersion())throw conflict("节点配置已变化，请刷新后核对");}
        else if(input.expectedVersion()!=-1)throw conflict("原节点配置已不存在");
        if(db.queryForObject("SELECT count(*) FROM finance_application_role_bindings WHERE role_key=? AND department_id IS NOT DISTINCT FROM ?::uuid AND id<>?",Integer.class,role.name(),input.departmentId(),input.id())>=8)throw invalid("一个岗位最多明确指定8名可代办人员，任一人只能办理本单当前节点");
        db.update("""
                INSERT INTO finance_application_role_bindings(id,role_key,department_id,employee_id,source_reference,updated_by) VALUES(?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET role_key=excluded.role_key,department_id=excluded.department_id,employee_id=excluded.employee_id,
                    source_reference=excluded.source_reference,row_version=finance_application_role_bindings.row_version+1,updated_at=now(),updated_by=excluded.updated_by
                """,input.id(),role.name(),input.departmentId(),assignee.employeeId(),reference,current.requireId());return settings();
    }
    @Transactional public Map<String,Object> removeRole(UUID id,long version){var user=staff();require(user,FinanceApplicationPermissions.SETTINGS);tx.bind();lockSettings();if(db.update("DELETE FROM finance_application_role_bindings WHERE id=? AND row_version=?",id,version)!=1)throw conflict("节点配置已变化，请刷新核对");return settings();}
    public boolean enabled(){return Boolean.TRUE.equals(db.queryForObject("SELECT enabled FROM finance_application_settings WHERE id=1",Boolean.class));}
    public boolean enabledWhenCreated(OffsetDateTime createdAt){return Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM finance_application_enable_periods WHERE enabled_at<=? AND (disabled_at IS NULL OR ?>=enabled_at AND ?<disabled_at))",Boolean.class,createdAt,createdAt,createdAt));}
    Assignment eligible(UUID raw,boolean throwIfMissing){
        var rows=db.queryForList("""
                SELECT e.id,u.id AS user_id,e.full_name FROM employees e JOIN users u ON u.employee_id=e.id
                WHERE e.id=fn_canonical_employee_identity(?) AND NOT e.is_deleted AND e.status<>'resigned'
                  AND NOT u.is_deleted AND u.status='active' ORDER BY u.id
                """,raw);
        for(var row:rows){UUID user=(UUID)row.get("user_id");var account=users.findById(user);if(account.isPresent()){
            var codes=permissions.grantedPermsOf(account.get());if(codes.contains(FinanceApplicationPermissions.VIEW)&&codes.contains(FinanceApplicationPermissions.REVIEW)&&codes.contains("attachment:view")&&codes.contains("attachment:download"))return new Assignment((UUID)row.get("id"),user,row.get("full_name").toString());
        }}
        if(throwIfMissing)throw invalid("指派人员需为在职启用员工账号，并具备各部门申请查看、节点处理及相关凭证查看/下载权限");return null;
    }
    List<Assignment> resolve(FinanceApplicationCatalog.Role role,UUID department,UUID applicant,Set<UUID> previousApprovers){
        List<UUID> ids=db.queryForList("SELECT employee_id FROM finance_application_role_bindings WHERE role_key=? AND department_id IS NOT DISTINCT FROM ?::uuid ORDER BY id",UUID.class,role.name(),role==FinanceApplicationCatalog.Role.DEPARTMENT_REVIEW?department:null);
        if(role==FinanceApplicationCatalog.Role.DEPARTMENT_REVIEW&&ids.isEmpty()&&department!=null)ids=db.queryForList("SELECT manager_id FROM departments WHERE id=? AND NOT is_deleted AND manager_id IS NOT NULL",UUID.class,department);
        List<Assignment> result=new ArrayList<>();for(UUID id:ids){var eligible=eligible(id,false);if(eligible!=null&&(role==FinanceApplicationCatalog.Role.FINANCE_CUSTODY||(!eligible.employeeId().equals(applicant)&&!previousApprovers.contains(eligible.employeeId())))&&result.stream().noneMatch(x->x.employeeId().equals(eligible.employeeId())))result.add(eligible);}return List.copyOf(result);
    }
    List<UUID> paymentRecipients(Map<String,Object> app){
        List<UUID> result=new ArrayList<>();var candidates=db.queryForList("SELECT u.id FROM users u JOIN employees e ON e.id=u.employee_id WHERE NOT u.is_deleted AND u.status='active' AND NOT e.is_deleted AND e.status<>'resigned' AND e.id<>fn_canonical_employee_identity(?) AND e.id<>fn_canonical_employee_identity(?)",UUID.class,app.get("applicant_id"),app.get("approved_by"));
        for(var account:users.findAllById(candidates)){var codes=permissions.grantedPermsOf(account);if(!codes.containsAll(Set.of("notice:read",FinanceApplicationPermissions.VIEW,FinanceApplicationPermissions.EXECUTE)))continue;
            boolean allowed=switch(app.get("source_kind").toString()){case "EXPENSE_CLAIM"->codes.contains("expense:pay");case "PAYROLL_BATCH"->true;default->{String nature=db.queryForObject("SELECT requested_payload->>'paymentNature' FROM finance_applications WHERE id=?",String.class,app.get("id"));yield "GENERAL_EXPENSE".equals(nature)?codes.containsAll(Set.of("finance_expense:create","finance_expense:approve")):codes.containsAll(Set.of("finance_payment:create","finance_payment:approve"));}};if(allowed)result.add(account.getId());}
        return List.copyOf(result);
    }
    static String text(String value,int max,String label){String result=value==null?"":value;if(result.length()>max)throw invalid(label+"过长");return result;}
    static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
