package com.uten.imp.features.expenseclaim;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.NativeApplicationContinuationPort;
import com.uten.imp.application.port.FinanceApplicationExpensePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Reuses the same real claim and its invoices/items. No second claim or payment. */
@Component @RequiredArgsConstructor
public class ExpenseApplicationContinuationAdapter implements NativeApplicationContinuationPort {
    private final ExpenseClaimService claims;
    private final FinanceApplicationExpensePort sources;
    private final ExpenseApplicationSourceService metadata;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final ObjectMapper json;
    private final ExpenseClaimRepository repository;
    private final ExpenseClaimReadPolicy readPolicy;
    @Override public String targetType(){return "EXPENSE_CLAIM";}
    @Override public boolean canContinueDraft(Draft draft,AuthUser actor){
        return actor!=null&&!actor.isVisitor()&&actor.getEmployeeId()!=null&&actor.getImpersonatedBy()==null
                &&actor.getPermissions().contains("expense:apply");
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public Result continueDraft(Draft draft){
        CurrentAuthorityGuard.requireAll("expense:apply");tx.bind();
        if(draft.expenseClaimId()==null||!draft.expenseClaimId().equals(draft.targetId()))throw invalid("接续须回到同一张原报销单");
        var claim=em.find(ExpenseClaim.class,draft.expenseClaimId(),LockModeType.PESSIMISTIC_WRITE);
        if(claim==null||claim.isDeleted()||!Set.of("DRAFT","REJECTED").contains(claim.getStatus())
                ||claim.getFinanceExpenseId()!=null||claim.getPaidAt()!=null)throw invalid("原报销目前不可修订，请先核对原审批和付款回执");
        var source=sources.source(claim.getId(),true);
        if(!source.applicantId().equals(current.requireEmployeeId()))throw new ApiException(ErrorCode.FORBIDDEN,"只能接续本人报销草稿");
        if(draft.expectedExpenseVersion()==null||claim.getVersion()!=draft.expectedExpenseVersion()
                ||!Objects.equals(source.fingerprint(),draft.expectedExpenseFingerprint()))throw invalid("原报销内容已变化，请重新审阅，不覆盖原输入");
        String kind="TRAVEL_REIMBURSEMENT".equals(draft.applicationKind())?"TRAVEL":"GENERAL";
        claim.setExpenseKind(kind);em.flush();
        metadata.save(claim.getId(),draft.applicationKind(),kind,draft.travelApplicationId(),draft.travelApplicationSourceKind());
        return read(claim.getId());
    }
    @Override public Result read(UUID id){return new Result(targetType(),id,"/expense/"+id,json.convertValue(claims.detail(id),new TypeReference<Map<String,Object>>(){}));}
    @Override public boolean mayRead(UUID id,AuthUser actor){
        if(actor==null||actor.isVisitor()||actor.getEmployeeId()==null)return false;
        var claim=repository.findById(id).orElse(null);if(claim==null)return false;
        boolean ownAbandoned=claim.isDeleted()&&claim.getAbandonedAt()!=null&&"REJECTED".equals(claim.getStatus())
                &&claim.getApplicantId().equals(actor.getEmployeeId())&&actor.getPermissions().contains("expense:apply");
        if(claim.isDeleted()&&!ownAbandoned)return false;
        var scope=actor.getPermissions().contains("expense:view")?readPolicy.scope(actor)
                :new com.uten.imp.security.OwnerVisibility.OwnerScope(false,Set.of(),Set.of());
        return readPolicy.canReadWorkflow(actor,claim,scope);
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
