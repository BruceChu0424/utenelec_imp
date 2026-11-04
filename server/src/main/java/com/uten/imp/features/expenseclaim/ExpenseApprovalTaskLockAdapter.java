package com.uten.imp.features.expenseclaim;

import com.uten.imp.application.port.ReviewTaskTargetLockPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.*;

/** Approval leases use exactly the write policy, including department and current-round separation. */
@Component
@RequiredArgsConstructor
class ExpenseApprovalTaskLockAdapter implements ReviewTaskTargetLockPort {
    private final ExpenseClaimRepository claims;
    private final ExpenseApprovalPolicy policy;
    private final ExpenseClaimReadPolicy readers;
    private final SecurityContextCurrentUser current;
    @Override public String targetType(){return "EXPENSE_APPROVE";}
    @Override public List<Target> resolve(List<String> keys,boolean requireExisting) {
        List<Target> out=new ArrayList<>();
        for(String key:keys.stream().distinct().sorted().toList()) {
            UUID id;
            try{id=UUID.fromString(key);}catch(IllegalArgumentException invalid){throw new ApiException(ErrorCode.VALIDATION_FAILED,"报销审批目标不正确");}
            if(requireExisting || claims.existsById(id))out.add(new Target(key,"EXPENSE_CLAIM",id,id));
        }
        return out;
    }
    @Override public void lockHeader(Target target,boolean requireReviewable) {
        var claim=claims.findByIdForUpdate(target.aggregateId()).filter(row->!row.isDeleted())
                .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"报销单不存在"));
        var user=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(requireReviewable)policy.requireApprove(user,claim);
        else if(!readers.canReadWorkflow(user,claim,readers.scope(user)))throw new ApiException(ErrorCode.NOT_FOUND,"报销单不存在");
    }
    @Override public void lockTarget(Target target,boolean requireReviewable){}
    @Override public boolean canViewTarget(String key) {
        UUID id;try{id=UUID.fromString(key);}catch(IllegalArgumentException invalid){return false;}
        var user=current.get().orElse(null);if(user==null || user.isVisitor())return false;
        return claims.findById(id).filter(row->!row.isDeleted()).map(row->readers.canReadWorkflow(user,row,readers.scope(user))).orElse(false);
    }
}
