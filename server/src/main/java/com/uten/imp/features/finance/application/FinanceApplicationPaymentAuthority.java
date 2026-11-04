package com.uten.imp.features.finance.application;

import com.uten.imp.application.port.*;
import com.uten.imp.common.web.*;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.util.*;

/** Stable read authorization for the independent payroll posting bridge. */
@Service @RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class FinanceApplicationPaymentAuthority implements FinanceApplicationPaymentAuthorityPort {
    private final JdbcTemplate db;private final FinanceApplicationRoles roles;private final SecurityContextCurrentUser current;
    private final TaskClaimService claims;
    @Override public Permit requirePayrollPreparation(UUID id,UUID batch,String expected){
        AuthUser actor=roles.live(FinanceApplicationPermissions.REVIEW);var app=payroll(id,batch);
        if(!Set.of("SUBMITTED","REVIEWING").contains(app.get("status")))throw conflict("工资申请当前不在财务复核节点");
        if(!Objects.equals(expected,app.get("source_fingerprint")))throw conflict("原工资内容已变化，请重新核对");
        int eligible=db.queryForObject("""
                SELECT count(*) FROM finance_application_nodes n WHERE n.application_id=? AND n.submission_round=? AND n.step_no=?
                    AND n.role_key='FINANCE_REVIEW_2' AND n.status='PENDING' AND EXISTS(SELECT 1 FROM jsonb_array_elements(n.assignees) a
                    WHERE fn_canonical_employee_identity((a->>'employeeId')::uuid)=fn_canonical_employee_identity(?))
                """,Integer.class,id,app.get("submission_round"),app.get("current_step"),actor.getEmployeeId());
        if(eligible!=1||same(actor.getEmployeeId(),(UUID)app.get("applicant_id")))throw new ApiException(ErrorCode.FORBIDDEN,"只有本单当前明确指派的财务复核人可准备原工资会计资料");
        claims.requireActiveClaimByMe("FINANCE_APPLICATION_REVIEW",id.toString());return permit(app,actor,List.of());
    }
    @Override public Permit requirePayrollExecution(FinancePayrollPaymentPort.Execute command){
        AuthUser actor=roles.live(FinanceApplicationPermissions.EXECUTE);var app=payroll(command.applicationId(),command.batchId());
        if(!"APPROVED".equals(app.get("status")))throw conflict("工资申请尚未批准支付或已有付款，请先核对原请求回执");
        if(!Objects.equals(command.sourceFingerprint(),app.get("source_fingerprint"))||command.instructionFingerprint()==null||!Objects.equals(command.instructionFingerprint(),app.get("payroll_instruction_fingerprint")))throw conflict("工资事实或已审核会计准备已变化，请重新复核");
        if(app.get("approved_by")==null||same(actor.getEmployeeId(),(UUID)app.get("approved_by"))||same(actor.getEmployeeId(),(UUID)app.get("applicant_id")))throw new ApiException(ErrorCode.FORBIDDEN,"实际支付人须与申请人及最终批准人分离");
        var evidence=proof(command.applicationId());boolean zero=app.get("amount_original") instanceof java.math.BigDecimal amount&&amount.signum()==0;if(!zero&&evidence.isEmpty())throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先上传本申请的真实银行付款回单或现金签收凭据并完成安全核验");
        return permit(app,actor,evidence);
    }
    @Override public Permit requirePayrollConfirmation(UUID id,UUID batch,UUID voucher){AuthUser actor=roles.live(FinanceApplicationPermissions.CONFIRM);var app=payroll(id,batch);posted(app,voucher);return permit(app,actor,List.of());}
    @Override public Permit requirePayrollReversal(UUID id,UUID batch,FinancePayrollPaymentPort.Reverse command){AuthUser actor=roles.live(FinanceApplicationPermissions.REVERSE);var app=payroll(id,batch);posted(app,command.paymentVoucherId());return permit(app,actor,List.of());}
    private Map<String,Object> payroll(UUID id,UUID batch){var rows=db.queryForList("SELECT * FROM finance_applications WHERE id=? FOR UPDATE",id);if(rows.size()!=1||!"PAYROLL_BATCH".equals(rows.getFirst().get("source_kind"))||!Objects.equals(batch,rows.getFirst().get("source_id")))throw new ApiException(ErrorCode.NOT_FOUND,"原工资付款申请不存在");return rows.getFirst();}
    private void posted(Map<String,Object> app,UUID voucher){
        if(!Set.of("EXECUTED","CONFIRMED").contains(app.get("status")))throw conflict("原工资尚未形成可确认/反审的真实办理回执");
        int matches=db.queryForObject("SELECT count(*) FROM finance_application_executions WHERE application_id=? AND doc_type='PAYROLL_PAYMENT' AND state IN('POSTED_PENDING_CONFIRMATION','CONFIRMED') AND ((?::uuid IS NOT NULL AND CASE WHEN result->>'receiptKind'='NON_CASH_CLEARED' THEN result->>'nonCashVoucherId' ELSE result->>'paymentVoucherId' END=?::text) OR (?::uuid IS NULL AND result->>'receiptKind'='NO_FINANCIAL_EVENT' AND result->>'paymentVoucherId' IS NULL AND result->>'nonCashVoucherId' IS NULL AND ?::numeric=0))",Integer.class,app.get("id"),voucher,voucher,voucher,app.get("amount_original"));
        if(matches!=1)throw conflict("当前工资付款凭证与原申请回执不一致");
    }
    private List<Evidence> proof(UUID id){return db.query("SELECT id,sha256,original_name FROM attachments WHERE owner_type='FINANCE_APPLICATION_PAYMENT_PROOF' AND owner_id=? AND lifecycle_state='CLEAN' AND delete_requested_at IS NULL AND sha256 IS NOT NULL ORDER BY id FOR SHARE",(rs,n)->new Evidence(rs.getObject(1,UUID.class),rs.getString(2),rs.getString(3)),id);}
    private Permit permit(Map<String,Object> app,AuthUser actor,List<Evidence> evidence){String name=db.queryForObject("SELECT full_name FROM employees WHERE id=fn_canonical_employee_identity(?)",String.class,actor.getEmployeeId());if(name==null||name.isBlank())throw conflict("实际操作人姓名尚未核对");return new Permit((UUID)app.get("id"),(UUID)app.get("source_id"),current.requireId(),actor.getEmployeeId(),name,(UUID)app.get("applicant_id"),(UUID)app.get("approved_by"),Objects.toString(app.get("source_fingerprint"),null),Objects.toString(app.get("payroll_instruction_fingerprint"),null),List.copyOf(evidence));}
    private boolean same(UUID a,UUID b){return a!=null&&b!=null&&Boolean.TRUE.equals(db.queryForObject("SELECT fn_canonical_employee_identity(?)=fn_canonical_employee_identity(?)",Boolean.class,a,b));}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
