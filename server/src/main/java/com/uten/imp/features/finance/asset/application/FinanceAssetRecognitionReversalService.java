package com.uten.imp.features.finance.asset.application;

import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.asset.api.*;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import java.time.YearMonth;
import java.util.*;

/** Reverses recognition as a business event; monthly facts must be reversed first. */
@Service @RequiredArgsConstructor
public class FinanceAssetRecognitionReversalService {
    private final EntityManager em;
    private final TxSessionVars tx;
    private final FinanceAssetAuthorization authorization;
    private final FinanceAssetLedgerPostingService ledger;
    private final FinanceAssetPeriodService periods;

    @Transactional @PreAuthorize("hasAuthority('finance_asset:reverse')")
    public AssetWorkbenchResponses.WorkflowResult request(UUID id,boolean deferred,AssetWorkbenchRequests.ReasonCommand command) {
        UUID actor=begin(deferred,FinanceAssetAuthorization.REVERSE,false);
        AssetOpeningGroupSupport.requireNoSingleReversal(em,type(deferred),id);
        var object=lock(id,deferred,command.expectedVersion());requireStatus(object,"ACTIVE");requireNoPostedFacts(id,deferred);
        if(object.voucher()==null)throw conflict("此资产缺少可追溯的初始确认凭证，请先完成历史账务核对");
        UUID request=UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO finance_asset_recognition_reversals(id,object_type,object_id,original_voucher_id,linked_opening,status,reason,requested_by)
                VALUES(:request,:type,:id,:voucher,:linked,'SUBMITTED',:reason,:actor)
                """).setParameter("request",request).setParameter("type",type(deferred)).setParameter("id",id)
                .setParameter("voucher",object.voucher()).setParameter("linked",object.linked())
                .setParameter("reason",reason(command.reason())).setParameter("actor",actor).executeUpdate();
        return transition(id,deferred,object,"RECOGNITION_REVERSAL_PENDING",actor,actor,"申请撤销初始确认",command.reason());
    }
    @Transactional @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult approve(UUID id,boolean deferred,AssetWorkbenchRequests.VersionCommand command) {
        UUID actor=begin(deferred,FinanceAssetAuthorization.APPROVE,false);
        var object=lock(id,deferred,command.expectedVersion());requireStatus(object,"RECOGNITION_REVERSAL_PENDING");
        var request=request(id,deferred);different(actor,request.maker());
        em.createNativeQuery("UPDATE finance_asset_recognition_reversals SET status='APPROVED',approved_by=:actor,approved_at=now() WHERE id=:id AND status='SUBMITTED'")
                .setParameter("actor",actor).setParameter("id",request.id()).executeUpdate();
        return transition(id,deferred,object,"RECOGNITION_REVERSAL_APPROVED",actor,request.maker(),"批准撤销初始确认",request.reason());
    }
    @Transactional @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult reject(UUID id,boolean deferred,AssetWorkbenchRequests.ReasonCommand command) {
        UUID actor=begin(deferred,FinanceAssetAuthorization.APPROVE,false);
        var object=lock(id,deferred,command.expectedVersion());requireStatus(object,"RECOGNITION_REVERSAL_PENDING");
        var request=request(id,deferred);different(actor,request.maker());
        em.createNativeQuery("UPDATE finance_asset_recognition_reversals SET status='REJECTED',approved_by=:actor,approved_at=now() WHERE id=:id")
                .setParameter("actor",actor).setParameter("id",request.id()).executeUpdate();
        return transition(id,deferred,object,"ACTIVE",actor,object.maker(),"退回初始确认撤销申请",reason(command.reason()));
    }
    @Transactional @PreAuthorize("hasAuthority('finance_asset:reverse')")
    public AssetWorkbenchResponses.WorkflowResult post(UUID id,boolean deferred,AssetWorkbenchRequests.VersionCommand command) {
        UUID actor=begin(deferred,FinanceAssetAuthorization.REVERSE,true);
        AssetOpeningGroupSupport.requireNoSingleReversal(em,type(deferred),id);
        var object=lock(id,deferred,command.expectedVersion());requireStatus(object,"RECOGNITION_REVERSAL_APPROVED");
        var request=request(id,deferred);different(actor,request.maker());requireNoPostedFacts(id,deferred);
        String period=YearMonth.from(BusinessTime.today()).toString();
        UUID reversal=null;
        if(!request.linked())reversal=ledger.reverse(object.voucher(),"REC-REV-"+request.id(),period,BusinessTime.today(),
                deferred?"DA_RECOGNITION_REV":"FA_CAP_REV",request.id(),"RECOGNITION_REVERSAL",request.reason());
        em.createNativeQuery("UPDATE "+table(deferred)+" SET recognition_reversed_on=:date,status='停用' WHERE id=:id")
                .setParameter("date",BusinessTime.today()).setParameter("id",id).executeUpdate();
        if(deferred)em.createNativeQuery("UPDATE finance_deferral_schedule_versions SET status='CANCELLED',row_version=row_version+1,updated_at=now(),updated_by=:actor WHERE deferred_id=:id AND NOT is_deleted")
                .setParameter("actor",actor).setParameter("id",id).executeUpdate();
        else em.createNativeQuery("UPDATE finance_asset_books SET status='CLOSED',posting_enabled=false,closed_at=now(),row_version=row_version+1,updated_at=now(),updated_by=:actor WHERE asset_id=:id AND NOT is_deleted")
                .setParameter("actor",actor).setParameter("id",id).executeUpdate();
        em.createNativeQuery("UPDATE finance_asset_recognition_reversals SET status='POSTED',posted_by=:actor,posted_at=now(),reversal_voucher_id=:voucher WHERE id=:id")
                .setParameter("actor",actor).setParameter("voucher",reversal).setParameter("id",request.id()).executeUpdate();
        return transition(id,deferred,object,"REVERSED",actor,request.maker(),request.linked()?"撤销旧资产台账接续，保留原有凭证":"初始确认已红冲",request.reason());
    }
    private UUID begin(boolean deferred,String permission,boolean posting) {
        tx.bind();PaymentStyleHierarchyLock.lock(em);UUID actor=authorization.requireActorId(permission);
        if(posting)periods.ensureOpen(YearMonth.from(BusinessTime.today()).toString(),permission);
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key","FINANCE_ASSET_RUN|"+(deferred?"AMORTIZATION":"DEPRECIATION")+"|CORPORATE").getSingleResult();
        return actor;
    }
    private ObjectState lock(UUID id,boolean deferred,long version) {
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("SELECT lifecycle_status,row_version,recognition_voucher_id,COALESCE(submitted_by,created_by),"
                +(deferred?"false":"opening_voucher_id IS NOT NULL")+" FROM "+table(deferred)+" WHERE id=:id AND NOT is_deleted FOR UPDATE")
                .setParameter("id",id).getResultList();
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND);
        Object[] r=rows.getFirst();if(((Number)r[1]).longValue()!=version)throw conflict("资产已变化，请刷新后重试");
        return new ObjectState(r[0].toString(),version,NativeValueConverters.uuid(r[2]),NativeValueConverters.uuid(r[3]),Boolean.TRUE.equals(r[4]));
    }
    private Request request(UUID id,boolean deferred) {
        Object[] r=(Object[])em.createNativeQuery("SELECT id,requested_by,reason,linked_opening FROM finance_asset_recognition_reversals WHERE object_type=:type AND object_id=:id AND status IN ('SUBMITTED','APPROVED') FOR UPDATE")
                .setParameter("type",type(deferred)).setParameter("id",id).getSingleResult();
        return new Request(NativeValueConverters.uuid(r[0]),NativeValueConverters.uuid(r[1]),r[2].toString(),Boolean.TRUE.equals(r[3]));
    }
    private void requireNoPostedFacts(UUID id,boolean deferred) {
        Number n=(Number)em.createNativeQuery("SELECT count(*) FROM "+(deferred?"da_amortization_log":"fa_depreciation_log")
                +" WHERE "+(deferred?"deferred_id":"asset_id")+"=:id AND entry_kind='NORMAL' AND status='ACTIVE' AND NOT is_deleted")
                .setParameter("id",id).getSingleResult();
        if(n.longValue()!=0)throw conflict("请先按期间倒序红冲该资产的全部折旧或摊销批次，再撤销初始确认");
    }
    private AssetWorkbenchResponses.WorkflowResult transition(UUID id,boolean deferred,ObjectState object,String status,
            UUID actor,UUID maker,String title,String reason) {
        com.uten.imp.features.finance.asset.domain.FinanceAssetStateMachine.requireObjectTransition(object.status(),status);
        int changed=em.createNativeQuery("UPDATE "+table(deferred)+" SET lifecycle_status=:status,row_version=row_version+1,updated_at=now(),updated_by=:actor WHERE id=:id AND row_version=:version")
                .setParameter("status",status).setParameter("actor",actor).setParameter("id",id).setParameter("version",object.version()).executeUpdate();
        if(changed!=1)throw conflict("资产已变化，请刷新后重试");
        em.createNativeQuery("""
                INSERT INTO finance_asset_events(object_type,object_id,event_type,title,description,effective_date,payload,actor_user_id,created_by,updated_by)
                VALUES(:type,:id,:event,:title,:reason,:date,'{}'::jsonb,:actor,:actor,:actor)
                """).setParameter("type",type(deferred)).setParameter("id",id).setParameter("event",status.equals("ACTIVE")?"RECOGNITION_REVERSAL_REJECTED":status)
                .setParameter("title",title).setParameter("reason",reason).setParameter("date",BusinessTime.today()).setParameter("actor",actor).executeUpdate();
        return new AssetWorkbenchResponses.WorkflowResult(id,status,null,object.version()+1,authorization.allowedActions(status,maker,deferred));
    }
    private static String table(boolean deferred){return deferred?"deferred_expenses":"fixed_assets";}
    private static String type(boolean deferred){return deferred?"DEFERRED_EXPENSE":"FIXED_ASSET";}
    private static void different(UUID actor,UUID maker){if(actor.equals(maker))throw conflict("申请人不能审批或执行自己的撤销申请");}
    private static void requireStatus(ObjectState object,String status){if(!object.status().equals(status))throw conflict("当前资产状态不能执行此操作");}
    private static String reason(String reason){if(reason==null||reason.isBlank())throw new ApiException(ErrorCode.VALIDATION_FAILED,"请填写原因");return reason.trim();}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private record ObjectState(String status,long version,UUID voucher,UUID maker,boolean linked){}
    private record Request(UUID id,UUID maker,String reason,boolean linked){}
}
