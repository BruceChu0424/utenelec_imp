package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.attachment.AttachmentOwnerAccessPolicy;
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

    @Override
    public String ownerType() {
        return OWNER_TYPE;
    }

    @Override
    public void requireCanView(UUID ownerId, AuthUser user) {
        ExpenseClaim claim = requireClaim(ownerId);
        if (claim.getApplicantId().equals(user.getEmployeeId()) && has(user, "expense:apply")) {
            return;
        }
        if (Set.of("SUBMITTED", "REVIEWING").contains(claim.getStatus())
                && has(user, "expense:approve")) {
            return;
        }
        if (Set.of("APPROVED", "PAID").contains(claim.getStatus())
                && has(user, "expense:pay")) {
            return;
        }
        // 与报销详情一致返回 404，避免用附件接口枚举无权单据。
        throw new ApiException(ErrorCode.NOT_FOUND, "报销单不存在");
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
        boolean editable = Set.of("DRAFT", "REJECTED").contains(claim.getStatus());
        if (editable
                && claim.getApplicantId().equals(user.getEmployeeId())
                && has(user, "expense:apply")) {
            return;
        }
        throw new ApiException(ErrorCode.NOT_FOUND, "报销单不存在或当前状态不可修改附件");
    }

    private ExpenseClaim requireClaim(UUID id) {
        if (id == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定业务单据");
        }
        return claimRepository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "报销单不存在"));
    }

    private static boolean has(AuthUser user, String permission) {
        return user.isSuperAdmin() || user.getPermissions().contains(permission);
    }
}
