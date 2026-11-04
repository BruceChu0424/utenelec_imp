package com.uten.imp.features.finance.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.*;

/** Versioned old-round authority. No date cutoff, link-presence shortcut or
 * permission to start another old round is inferred from an old approval. */
@Component @RequiredArgsConstructor
public class FinanceApplicationLegacyPolicy {
    private final JdbcTemplate db;

    public boolean payroll(Map<String,Object> application) {
        return "PAYROLL_PAYMENT".equals(application.get("kind"))
                && "PAYROLL_BATCH".equals(application.get("source_kind")) && application.get("source_id")!=null;
    }
    public boolean allowed(UUID id) {
        return Boolean.TRUE.equals(db.queryForObject("SELECT fn_finance_application_legacy_round_allowed(?)",Boolean.class,id));
    }
    public void requireRound(Map<String,Object> application) {
        if(!allowed((UUID)application.get("id")))
            throw conflict("原轮已结束或没有对应冻结授权，请审阅后按当前申请流程继续");
    }
    public void requireNewRound(Map<String,Object> application) {
        if(!payroll(application)) throw conflict("新的申请轮次由当前审批流程办理，请先审阅原稿继续");
    }
    public void requireCreation(FinanceApplicationCatalog.Kind kind) {
        if(kind!=FinanceApplicationCatalog.Kind.PAYROLL_PAYMENT)
            throw conflict("新申请须审阅后按当前申请流程继续；本次未建立旧审批单");
    }
    public boolean mapped(UUID id) {
        return Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM finance_application_native_mappings WHERE original_application_id=? OR origin_id=?)",Boolean.class,id,id));
    }
    public void requireEditableOriginal(Map<String,Object> application) {
        if(payroll(application)) return;
        UUID id=(UUID)application.get("id");
        if(mapped(id)) throw conflict("原稿已按当前流程继续并冻结，请打开对应当前申请");
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM finance_application_legacy_sources WHERE application_id=?)",Boolean.class,id)))
            throw conflict("此记录没有原稿接续依据，请保留原请求并核对结果");
    }
    /** Canonical employee identities, never displayed names, define separation. */
    public void requireUninvolvedPayer(Map<String,Object> application,UUID actor) {
        boolean involved=!uninvolvedPayer(application,actor);
        if(involved) throw new ApiException(ErrorCode.FORBIDDEN,"实际付款须由与申请人及本轮所有已实审人员分离的人员登记");
    }
    public boolean uninvolvedPayer(Map<String,Object> application,UUID actor) {
        UUID id=(UUID)application.get("id");
        return !Boolean.TRUE.equals(db.queryForObject("""
            SELECT fn_canonical_employee_identity(?::uuid)=fn_canonical_employee_identity(app.applicant_id)
              OR EXISTS(SELECT 1 FROM finance_application_nodes node
                WHERE node.application_id=app.id AND node.submission_round=app.submission_round
                  AND node.decided_by IS NOT NULL AND node.status IN('APPROVED','ARCHIVED')
                  AND fn_canonical_employee_identity(node.decided_by)=fn_canonical_employee_identity(?::uuid))
            FROM finance_applications app WHERE app.id=?
            """,Boolean.class,actor,actor,id));
    }
    private static ApiException conflict(String message) {return new ApiException(ErrorCode.CONFLICT,message);}
}
