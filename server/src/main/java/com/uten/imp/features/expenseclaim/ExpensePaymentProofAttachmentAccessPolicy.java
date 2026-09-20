package com.uten.imp.features.expenseclaim;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.UUID;

/** Payment evidence is separate from the applicant's approved expense evidence. */
@Component
@RequiredArgsConstructor
public class ExpensePaymentProofAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE="EXPENSE_PAYMENT_PROOF";
    private final ExpenseClaimRepository claims;
    private final ExpenseClaimAttachmentAccessPolicy claimReadPolicy;
    @Override public String ownerType(){return OWNER_TYPE;}
    @Override public void requireCanView(UUID ownerId,AuthUser user){claimReadPolicy.requireCanView(ownerId,user);}
    @Override public void requireCanManage(UUID ownerId,AuthUser user){
        requirePayer(claims.findById(ownerId).orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"报销单不存在")),user);
    }
    @Override public void requireCanManageForUpdate(UUID ownerId,AuthUser user){
        if(ownerId==null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"付款凭据必须绑定报销单");
        requirePayer(claims.findByIdForUpdate(ownerId).orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"报销单不存在")),user);
    }
    private static void requirePayer(ExpenseClaim claim,AuthUser user){
        if(user.isVisitor() || user.getEmployeeId()==null || (!user.isSuperAdmin() && !user.getPermissions().contains("expense:pay"))
                || !"APPROVED".equals(claim.getStatus()) || user.getEmployeeId().equals(claim.getApplicantId())
                || user.getEmployeeId().equals(claim.getApprovedBy()))
            throw new ApiException(ErrorCode.NOT_FOUND,"报销单不存在或当前不可维护付款凭据");
    }
}
