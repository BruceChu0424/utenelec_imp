package com.uten.imp.features.finance.application;

import com.uten.imp.application.port.*;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.*;

/** Native source header -> application -> lease, shared by take/renew/decision. */
@Component @RequiredArgsConstructor
public class FinanceApplicationClaimTargetLocks implements ReviewTaskTargetLockPort {
    private final JdbcTemplate db;private final FinanceApplicationRoles roles;private final FinanceApplicationExpensePort expenses;
    private final ObjectProvider<FinancePayrollPaymentPort> payroll;
    private final FinanceApplicationReadAccess reads;private final FinanceApplicationLegacyPolicy legacy;
    @Override public String targetType(){return "FINANCE_APPLICATION_REVIEW";}
    @Override public Set<String> readableTargetKeys(Collection<String> keys){
        if(keys.isEmpty())return Set.of();List<UUID> ids=new ArrayList<>();for(var key:keys)try{UUID id=UUID.fromString(key);if(id.toString().equals(key))ids.add(id);}catch(IllegalArgumentException ignored){}
        return reads.readableIds(ids,roles.staff()).stream().map(UUID::toString).collect(java.util.stream.Collectors.toUnmodifiableSet());
    }
    @Override public List<Target> resolve(List<String> keys,boolean requireExisting){
        var allowed=readableTargetKeys(keys);
        List<Target> result=new ArrayList<>();for(String key:keys){UUID id;try{id=UUID.fromString(key);if(!id.toString().equals(key))throw new IllegalArgumentException();}catch(Exception e){if(requireExisting)throw new ApiException(ErrorCode.VALIDATION_FAILED,"申请编号不正确，请刷新");continue;}
            if(!allowed.contains(key)){if(requireExisting)throw new ApiException(ErrorCode.NOT_FOUND,"原申请不存在或不在明确参与范围内");continue;}var rows=db.queryForList("SELECT source_kind,source_id FROM finance_applications WHERE id=?",id);if(rows.isEmpty()){if(requireExisting)throw conflict("申请不存在或已变化");continue;}
            String kind=rows.getFirst().get("source_kind").toString();UUID source=(UUID)rows.getFirst().get("source_id");boolean nativeHeader=Set.of("EXPENSE_CLAIM","PAYROLL_BATCH").contains(kind);
            if(nativeHeader&&source==null){if(requireExisting)throw conflict("申请原始来源尚未完整对应");continue;}result.add(new Target(key,nativeHeader?kind:"FINANCE_APPLICATION",nativeHeader?source:id,id));
        }return List.copyOf(result);
    }
    @Override public void lockHeader(Target target,boolean requireReviewable){switch(target.aggregateType()){
        case "EXPENSE_CLAIM"->expenses.source(target.aggregateId(),true);
        case "PAYROLL_BATCH"->{var bridge=payroll.getIfAvailable();if(bridge==null)throw conflict("原工资事实桥尚未可用");bridge.source(target.aggregateId(),true);}
        default->db.queryForList("SELECT id FROM finance_applications WHERE id=? FOR UPDATE",target.aggregateId());
    }}
    @Override public void lockTarget(Target target,boolean requireReviewable){
        var rows=db.queryForList("SELECT id,status,submission_round,current_step,applicant_id FROM finance_applications WHERE id=? FOR UPDATE",target.targetId());if(!requireReviewable)return;
        if(rows.isEmpty()||!Set.of("SUBMITTED","REVIEWING").contains(rows.getFirst().get("status")))throw conflict("申请已不在当前待办理节点");var app=rows.getFirst();legacy.requireRound(app);var actor=roles.live(FinanceApplicationPermissions.REVIEW);
        int valid=db.queryForObject("""
                SELECT count(*) FROM finance_application_nodes n WHERE n.application_id=? AND n.submission_round=? AND n.step_no=? AND n.status='PENDING'
                  AND EXISTS(SELECT 1 FROM jsonb_array_elements(n.assignees) a WHERE fn_canonical_employee_identity((a->>'employeeId')::uuid)=fn_canonical_employee_identity(?))
                  AND (n.action='ARCHIVE' OR (fn_canonical_employee_identity(?)<>fn_canonical_employee_identity(?)
                    AND NOT EXISTS(SELECT 1 FROM finance_application_nodes p WHERE p.application_id=n.application_id AND p.submission_round=n.submission_round
                        AND p.status='APPROVED' AND fn_canonical_employee_identity(p.decided_by)=fn_canonical_employee_identity(?))))
                """,Integer.class,target.targetId(),app.get("submission_round"),app.get("current_step"),actor.getEmployeeId(),actor.getEmployeeId(),app.get("applicant_id"),actor.getEmployeeId());
        if(valid!=1)throw new ApiException(ErrorCode.FORBIDDEN,"只有本单当前明确指派且未重复审核的人员可认领该步骤");
    }
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
