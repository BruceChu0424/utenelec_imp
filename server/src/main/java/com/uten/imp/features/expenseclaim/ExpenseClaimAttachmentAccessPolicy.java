package com.uten.imp.features.expenseclaim;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Set;
import java.util.UUID;

/** 报销单附件的对象级授权；语义与 {@link ExpenseClaimService#detail(UUID)} 保持一致。 */
@Component
@RequiredArgsConstructor
public class ExpenseClaimAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {

    public static final String OWNER_TYPE = "EXPENSE_CLAIM";

    private final ExpenseClaimRepository claimRepository;
    @org.springframework.beans.factory.annotation.Autowired
    private ExpenseClaimReadPolicy readAccess;

    @Override
    public String ownerType() {
        return OWNER_TYPE;
    }

    @Override
    public void requireCanView(UUID ownerId, AuthUser user) {
        ExpenseClaim claim=requireClaim(ownerId,true);
        boolean ownAbandoned=claim.isDeleted()&&claim.getAbandonedAt()!=null&&"REJECTED".equals(claim.getStatus())
                &&user!=null&&claim.getApplicantId().equals(user.getEmployeeId())&&has(user,"expense:apply");
        if(claim.isDeleted()&&!ownAbandoned)throw new ApiException(ErrorCode.NOT_FOUND,"报销单不存在");
        readable(claim,user);
    }
    @Override public void requireCanViewHistory(UUID ownerId,AuthUser user) {
        readable(requireClaim(ownerId,true),user);
    }
    @Override public void requireCanViewSensitiveOriginalHistory(UUID ownerId,AuthUser user) { requireCanViewHistory(ownerId,user); }
    private void readable(ExpenseClaim claim,AuthUser user) {
        var scope=user.getPermissions().contains("expense:view") ? readAccess.scope(user)
                : new com.uten.imp.security.OwnerVisibility.OwnerScope(false,Set.of(),Set.of());
        if (!ExpenseClaimReadPolicy.canRead(user,claim,scope) && (readAccess==null || !readAccess.canReadWorkflow(user,claim,scope))) {
            throw new ApiException(ErrorCode.NOT_FOUND,"报销单不存在");
        }
    }

    @Override
    public void requireCanManage(UUID ownerId, AuthUser user) {
        ExpenseClaim claim = requireClaim(ownerId);
        requireEditableOwner(claim, user);
    }

    @Override
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        if (ownerId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定业务单据");
        }
        ExpenseClaim claim = claimRepository.findByIdForUpdate(ownerId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "报销单不存在"));
        requireEditableOwner(claim, user);
    }

    private static void requireEditableOwner(ExpenseClaim claim, AuthUser user) {
        boolean editable = !claim.isDeleted() && Set.of("DRAFT", "REJECTED").contains(claim.getStatus());
        if (editable
                && claim.getApplicantId().equals(user.getEmployeeId())
                && has(user, "expense:apply")) {
            return;
        }
        throw new ApiException(ErrorCode.NOT_FOUND, "报销单不存在或当前状态不可修改附件");
    }

    private ExpenseClaim requireClaim(UUID id) { return requireClaim(id,false); }

    private ExpenseClaim requireClaim(UUID id, boolean includeDeleted) {
        if (id == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定业务单据");
        }
        return claimRepository.findById(id).filter(claim -> includeDeleted || !claim.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "报销单不存在"));
    }

    private static boolean has(AuthUser user, String permission) {
        return user.getPermissions().contains(permission);
    }
}
