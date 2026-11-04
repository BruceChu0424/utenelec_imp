package com.uten.imp.features.applications;

import com.uten.imp.application.port.NativeApplicationContinuationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.UUID;

/** Main application service remains the sole creator and approval authority. */
@Component @RequiredArgsConstructor
public class BusinessApplicationContinuationAdapter implements NativeApplicationContinuationPort {
    private final BusinessApplicationService service;
    @Override public String targetType(){return "BUSINESS_APPLICATION";}
    @Override public boolean canContinueDraft(Draft draft,AuthUser actor){
        return actor!=null&&!actor.isVisitor()&&actor.getEmployeeId()!=null&&actor.getImpersonatedBy()==null
                &&BusinessApplicationWorkflow.KINDS.containsKey(draft.businessKind())
                &&(actor.getPermissions().contains("application:apply")
                ||actor.getPermissions().contains(BusinessApplicationWorkflow.applyPermission(draft.businessKind())));
    }
    @Override public void validateDraft(Draft draft){service.validate(new BusinessApplicationController.Input(draft.targetId(),draft.businessKind(),draft.title(),draft.amount(),new java.util.LinkedHashMap<>(draft.fields()),null));}
    @Override public Result continueDraft(Draft draft){
        if(draft.targetId()==null||draft.expenseClaimId()!=null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"当前申请来源类型不一致");
        var value=service.create(new BusinessApplicationController.Input(draft.targetId(),draft.businessKind(),
                draft.title(),draft.amount(),new java.util.LinkedHashMap<>(draft.fields()),null));
        return new Result(targetType(),draft.targetId(),"/applications/"+draft.targetId(),value);
    }
    @Override public Result read(UUID id){return new Result(targetType(),id,"/applications/"+id,service.detail(id));}
    @Override public boolean mayRead(UUID id,AuthUser actor){
        if(actor==null||actor.isVisitor()||actor.getEmployeeId()==null)return false;
        try{service.readable(service.row(id,false),actor);return true;}
        catch(ApiException denied){return false;}
    }
}
