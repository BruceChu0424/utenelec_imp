package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.BusinessOutboxDomainHandler;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.UUID;

/** Durable configuration/manager-change receipts; no approval decision is fabricated. */
@Component
@RequiredArgsConstructor
public class DepartmentApprovalRoutingChangedHandler implements BusinessOutboxDomainHandler {
    public static final String EVENT="DEPARTMENT_APPROVAL_ROUTING_CHANGED";
    private final JdbcTemplate jdbc;
    private final NoticeService notices;
    @Override public boolean supports(String event){return EVENT.equals(event);}
    @Override public void handle(UUID eventId,String event,UUID department,JsonNode payload,UUID createdBy) {
        if(department==null)throw new IllegalArgumentException("Routing change is missing its department");
        notifyStale("expense_claims","applicant_department_id","approval_round","/expense/",department);
        notifyStale("business_applications","department_id","round","/applications/",department);
    }
    private void notifyStale(String table,String departmentField,String roundField,String route,UUID department) {
        String select="""
            WITH RECURSIVE affected(id) AS (SELECT ?::uuid UNION SELECT d.id FROM departments d JOIN affected p ON d.parent_id=p.id)
            SELECT c.id,c.applicant_id,c.%s FROM %s c WHERE c.%s IN(SELECT id FROM affected)
              AND c.status IN('SUBMITTED','REVIEWING') AND c.approval_stage='DEPARTMENT'
              AND c.routing_stale_notified_round IS DISTINCT FROM c.%s
              AND fn_department_approval_snapshot_stale(c.applicant_id,c.%s,c.department_approval_snapshot)
            """.formatted(roundField,table,departmentField,roundField,departmentField);
        if("expense_claims".equals(table))select+=" AND NOT c.is_deleted";
        select+=" FOR UPDATE OF c";
        for(var row:jdbc.queryForList(select,department)) {
            UUID id=(UUID)row.get("id"),applicant=(UUID)row.get("applicant_id");
            for(UUID user:jdbc.queryForList("SELECT id FROM users WHERE employee_id=? AND NOT is_deleted AND status='active'",UUID.class,applicant))
                notices.publishForUser(user,"审批安排已变化，请撤回重提","部门负责人或回避审批配置已变化，请撤回并重新提交；已填写内容和真实审批记录会保留。","workflow","审批中心",route+id);
            jdbc.update("UPDATE "+table+" SET routing_stale_notified_round="+roundField+" WHERE id=?",id);
        }
    }
}
