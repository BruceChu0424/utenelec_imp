package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/** Supplier return/credit originals use the same owner scope and amount gate as the case. */
@Component
@RequiredArgsConstructor
public class ProcurementIqcRejectionAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    private final ProcurementIqcRejectionService service;

    @Override public String ownerType() { return "PROCUREMENT_IQC_REJECTION"; }

    @Override public void requireCanView(UUID id, AuthUser user) {
        requirePermissions(id, user);
        requireUnmasked(service.attachmentOwnerView(id));
    }

    @Override public void requireCanManage(UUID id, AuthUser user) {
        requirePermissions(id, user);
        requireWritable(service.attachmentOwnerView(id));
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID id, AuthUser user) {
        requirePermissions(id, user);
        requireWritable(service.lockAttachmentOwner(id));
    }

    private static void requirePermissions(UUID id, AuthUser user) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先保存业务单据");
        if (!user.isSuperAdmin() && !(user.getPermissions().contains("procurement_iqc_rejection:view")
                && user.getPermissions().contains("procurement_iqc_rejection:amount:view"))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "查看原始文件需要本单查看和金额查看权限");
        }
    }

    private static void requireUnmasked(ProcurementIqcRejectionContracts.CaseItem item) {
        if (item.priceMasked()) throw new ApiException(ErrorCode.FORBIDDEN, "当前无权查看原始文件中的金额");
    }

    private static void requireWritable(ProcurementIqcRejectionContracts.CaseItem item) {
        requireUnmasked(item);
        if (item.allowedActions().stream().noneMatch(action ->
                action.equals("RECORD_RETURN") || action.equals("CONFIRM_CREDIT"))) {
            throw new ApiException(ErrorCode.CONFLICT, "当前任务不能修改文件；已完成的退回或贷项记录需保留原始凭证");
        }
    }
}
