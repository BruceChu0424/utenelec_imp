package com.uten.imp.features.finance.application;

import com.uten.imp.application.port.*;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.time.*;
import java.util.*;

/** Source gateways cannot bypass an activated original workflow or broaden a reviewer to the legacy pool. */
@Service @RequiredArgsConstructor
public class FinanceApplicationSourceControl implements FinanceApplicationControlPort {
    private final JdbcTemplate db;private final FinanceApplicationRoles roles;private final FinanceApplicationExpensePort expenses;
    private final ObjectProvider<FinanceApplicationService> applications;private final SecurityContextCurrentUser current;
    private final FinanceApplicationReadAccess reads;private final FinanceApplicationLegacyPolicy legacy;
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void registerExpenseDraft(UUID claim,String raw,UUID travel){
        var rows=db.queryForList("SELECT app.* FROM finance_expense_application_links link JOIN finance_applications app ON app.id=link.application_id WHERE link.claim_id=? AND app.source_kind='EXPENSE_CLAIM' AND app.source_id=? FOR UPDATE OF app",claim,claim);
        if(rows.isEmpty())throw conflict("新报销来源由当前流程保存，不得建立旧审批关联");
        var app=rows.getFirst();legacy.requireEditableOriginal(app);
        if(raw!=null&&!raw.equals(app.get("kind")))throw conflict("原申请类型不能在旧关联中替换，请审阅后按当前流程继续");
        if(travel!=null&&!Objects.equals(travel,app.get("travel_application_id")))throw conflict("原出差来源已变化，请先审阅原稿");
    }
    @Override public void requireExpenseMainAuthority(UUID claim){
        var ids=db.queryForList("SELECT app.id FROM finance_expense_application_links link JOIN finance_applications app ON app.id=link.application_id WHERE link.claim_id=? AND app.source_kind='EXPENSE_CLAIM' AND app.source_id=?",UUID.class,claim,claim);
        if(!ids.isEmpty()&&!legacy.mapped(ids.getFirst()))throw conflict("这张原报销须先审阅原稿并接续当前流程；本次未提交、审批或付款");
    }

    @Override @Transactional(propagation=Propagation.MANDATORY) public boolean expenseSubmitted(UUID claim){return applications.getObject().submittedExpense(claim);}
    @Override @Transactional(propagation=Propagation.MANDATORY) public void expenseWithdrawn(UUID claim){if(!NativeApplicationContext.matches(claim,NativeApplicationContext.Action.WITHDRAW))applications.getObject().withdrawnExpense(claim);}
    @Override public boolean expenseManaged(UUID claim){
        var ids=db.queryForList("SELECT app.id FROM finance_expense_application_links link JOIN finance_applications app ON app.id=link.application_id WHERE link.claim_id=? AND app.source_kind='EXPENSE_CLAIM' AND app.source_id=? AND app.status IN('SUBMITTED','REVIEWING','APPROVED','EXECUTED','CONFIRMED')",UUID.class,claim,claim);
        return ids.stream().anyMatch(id->legacy.allowed(id)&&!legacy.mapped(id));
    }

    @Override public boolean mayReadExpense(UUID claim,AuthUser actor){var links=db.queryForList("SELECT application_id FROM finance_expense_application_links WHERE claim_id=? AND application_id IS NOT NULL",UUID.class,claim);return !links.isEmpty()&&reads.readableIds(links,actor).contains(links.getFirst());}
    @Override public Set<UUID> readableApplications(Collection<UUID> ids,AuthUser actor){return reads.readableIds(ids,actor);}
    @Override public void requireLegacyExpenseDecision(UUID claim){requireExpenseMainAuthority(claim);if(expenseManaged(claim))throw conflict("本单已进入各部门申请流程，请按当前明确节点办理，不能从原单跳级审批");}
    @Override public void requireExpenseDecisionContext(UUID claim){context(claim,NativeApplicationContext.Action.DECIDE,FinanceApplicationPermissions.REVIEW);}
    @Override public void requireExpenseInvoiceVerification(UUID claim){var app=context(claim,NativeApplicationContext.Action.VERIFY,FinanceApplicationPermissions.REVIEW);int n=db.queryForObject("SELECT count(*) FROM finance_application_nodes WHERE application_id=? AND submission_round=? AND step_no=? AND status='PENDING' AND role_key IN('FINANCE_REVIEW_1','FINANCE_REVIEW_2')",Integer.class,app.get("id"),app.get("submission_round"),app.get("current_step"));if(n!=1)throw conflict("请由本单当前明确指派的财务复核节点核验原报销票据");}
    @Override public void requireExpensePayment(UUID claim){if(expenseManaged(claim)){var app=context(claim,NativeApplicationContext.Action.PAY,FinanceApplicationPermissions.EXECUTE);approved(app);if(db.queryForList("SELECT id FROM attachments WHERE owner_type='FINANCE_APPLICATION_PAYMENT_PROOF' AND owner_id=? AND lifecycle_state='CLEAN' AND delete_requested_at IS NULL AND sha256 IS NOT NULL FOR SHARE",app.get("id")).isEmpty())throw conflict("请先完成原申请实际付款凭证安全核验");}}
    @Override public void requireExpenseReversalContext(UUID claim,UUID expense){var value=NativeApplicationContext.current();if(value==null||value.action()!=NativeApplicationContext.Action.REVERSE||(!value.sourceId().equals(claim)&&!value.sourceId().equals(expense)))throw conflict("请从原申请反审实际报销单付款");roles.live(FinanceApplicationPermissions.REVERSE);var app=applications.getObject().row(value.applicationId(),true);legacy.requireRound(app);int same=db.queryForObject("SELECT count(*) FROM finance_application_executions x JOIN finance_expense_application_links l ON l.application_id=x.application_id WHERE x.application_id=? AND x.doc_type='EXPENSE' AND x.doc_id=? AND l.claim_id=? AND x.state IN('POSTED_PENDING_CONFIRMATION','CONFIRMED')",Integer.class,app.get("id"),expense,claim);if(same!=1)throw conflict("原财务付款身份与申请回执不一致");}
    @Override public void requirePaymentExecution(UUID id){nativeExecution("PAYMENT","finance_payments",id,NativeApplicationContext.Action.POST_PAYMENT);}
    @Override public void requireExpenseExecution(UUID id){nativeExecution("EXPENSE","finance_expenses",id,NativeApplicationContext.Action.POST_EXPENSE);}
    @Override public NativePermit requireNativeCreation(String type){
        var value=NativeApplicationContext.current();var action=type.equals("PAYMENT")?NativeApplicationContext.Action.POST_PAYMENT:NativeApplicationContext.Action.POST_EXPENSE;
        if(value==null||value.action()!=action)throw conflict("请从已批准的原申请登记实际付款");var app=applications.getObject().row(value.applicationId(),true);approved(app);roles.live(FinanceApplicationPermissions.EXECUTE);
        var actor=roles.staff();String prefix=type.equals("PAYMENT")?"finance_payment:":"finance_expense:";roles.require(actor,prefix+"create",prefix+"approve");
        return new NativePermit((UUID)app.get("id"),(UUID)app.get("applicant_id"),(UUID)app.get("approved_by"),app.get("approved_name_snapshot").toString());
    }
    @Override public NativePermit nativeExecutionPermit(String type,UUID id){
        nativeExecution(type,type.equals("PAYMENT")?"finance_payments":"finance_expenses",id,type.equals("PAYMENT")?NativeApplicationContext.Action.POST_PAYMENT:NativeApplicationContext.Action.POST_EXPENSE);
        var links=db.queryForList("SELECT application_id FROM finance_application_executions WHERE doc_type=? AND doc_id=?",UUID.class,type,id);if(links.isEmpty())return null;
        return requireNativeCreation(type);
    }
    @Override public void requireNativeSettlementAction(String type,UUID id,String action){
        var links=db.queryForList("SELECT application_id FROM finance_application_executions WHERE doc_type=? AND doc_id=?",UUID.class,type,id);if(links.isEmpty())return;
        var expected=action.equals("CONFIRM")?NativeApplicationContext.Action.CONFIRM:NativeApplicationContext.Action.REVERSE;
        var app=context(id,expected,action.equals("CONFIRM")?FinanceApplicationPermissions.CONFIRM:FinanceApplicationPermissions.REVERSE);
        if(!links.contains(app.get("id"))||!Set.of("EXECUTED","CONFIRMED").contains(app.get("status")))throw conflict("原申请或实际付款状态已变化，请从原申请核对");
    }
    private void nativeExecution(String type,String table,UUID id,NativeApplicationContext.Action action){
        var sources=db.queryForList("SELECT created_at,legacy_id FROM "+table+" WHERE id=?",id);if(sources.isEmpty())throw conflict("原财务支出不存在");var links=db.queryForList("SELECT application_id FROM finance_application_executions WHERE doc_type=? AND doc_id=?",UUID.class,type,id);
        if(links.isEmpty())return; // Native employee/application workflows own their new approvals; legacy links retain their frozen gate.
        var app=context(id,action,FinanceApplicationPermissions.EXECUTE);if(!links.contains(app.get("id")))throw conflict("实际资金单未对应原批准申请");approved(app);
    }
    private Map<String,Object> context(UUID source,NativeApplicationContext.Action action,String permission){if(!NativeApplicationContext.matches(source,action))throw conflict("请从原申请的当前授权动作办理，不能绕过申请节点");roles.live(permission);var value=NativeApplicationContext.current();var app=applications.getObject().row(value.applicationId(),true);legacy.requireRound(app);return app;}
    private void approved(Map<String,Object> app){if(!"APPROVED".equals(app.get("status"))||app.get("approved_by")==null)throw conflict("原申请尚未批准支付或已登记付款");applications.getObject();UUID actor=current.requireEmployeeId();legacy.requireRound(app);legacy.requireUninvolvedPayer(app,actor);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
