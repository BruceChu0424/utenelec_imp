package com.uten.imp.features.sales.quote;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.UUID;

/** Attachments follow the same exact owner as the document and freeze at approval. */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class SalesQuoteAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "SALES_QUOTE";
    private final EntityManager em;
    private final SalesDocumentAccessPolicy access;

    @Override public String ownerType() { return OWNER_TYPE; }
    @Override public void requireCanView(UUID ownerId, AuthUser user) { readable(document(ownerId), user); }
    @Override public void requireCanManage(UUID ownerId, AuthUser user) { editable(document(ownerId), user); }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        editable(document(ownerId), user);
        SalesQuote locked = em.find(SalesQuote.class, ownerId, LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) throw missing();
        em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
        editable(locked, user);
    }

    private SalesQuote document(UUID id) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定销售报价单");
        SalesQuote document = em.find(SalesQuote.class, id);
        if (document == null || document.isDeleted()) throw missing();
        return document;
    }
    private void readable(SalesQuote document, AuthUser user) {
        if (document.isDeleted() || !has(user, "sales_quote:view")) throw missing();
        access.requireReadable(document.getMakerId(), "销售报价单不存在");
    }
    private void editable(SalesQuote document, AuthUser user) {
        readable(document, user);
        if (!has(user, "sales_quote:edit")) throw new ApiException(ErrorCode.FORBIDDEN, "缺少销售报价单编辑权限");
        access.requireWritable(document.getMakerId(), "无权修改该销售报价单附件");
        if (document.getStatus() == null || document.getStatus() != 0 || document.isClosed()) {
            throw new ApiException(ErrorCode.CONFLICT, "仅未关闭的草稿销售报价单可修改附件，审核后原件只读");
        }
    }
    private static boolean has(AuthUser user, String permission) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(permission));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在"); }
}
