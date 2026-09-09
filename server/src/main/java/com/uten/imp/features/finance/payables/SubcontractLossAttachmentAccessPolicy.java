package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Set;
import java.util.UUID;

/** The original evidence is frozen once the responsibility decision is made. */
@Component
@RequiredArgsConstructor
public class SubcontractLossAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    private final SubcontractLossClaimService service;

    @Override public String ownerType() { return "SUBCONTRACT_LOSS_CASE"; }

    @Override public void requireCanView(UUID id, AuthUser user) {
        requirePermissions(id, user, false);
        requireUnmasked(service.attachmentOwnerView(id));
    }

    @Override public void requireCanManage(UUID id, AuthUser user) {
        requirePermissions(id, user, true);
        requireWritable(service.attachmentOwnerView(id));
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID id, AuthUser user) {
        requirePermissions(id, user, true);
        requireWritable(service.lockAttachmentOwner(id));
    }

    private static void requirePermissions(UUID id, AuthUser user, boolean edit) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先保存业务单据");
        if (!user.isSuperAdmin() && !(user.getPermissions().contains("subcontract_loss_claim:view")
                && user.getPermissions().contains("finance:view:all")
                && (!edit || user.getPermissions().contains("subcontract_loss_claim:review")))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前没有这份原始文件的查看或办理权限");
        }
    }

    private static void requireUnmasked(SubcontractLossClaimContracts.CaseSummary item) {
        if (item.priceMasked()) throw new ApiException(ErrorCode.FORBIDDEN, "当前无权查看原始文件中的金额");
    }

    private static void requireWritable(SubcontractLossClaimContracts.CaseSummary item) {
        requireUnmasked(item);
        if (!Set.of("OPEN", "DISPUTED").contains(item.status())) {
            throw new ApiException(ErrorCode.CONFLICT, "已作出责任决定，原始文件仅供查看");
        }
    }
}
