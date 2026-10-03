package com.uten.imp.features.sales.quote;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.UUID;

/**
 * 报价附件跟随报价的负责人(maker_id), 只在草稿(含财务退回的草稿)可增删, 提交核价后原件只读。
 * 核价人(sales_quote_finance:view)可只读查看待核价/已核价/本轮退回的报价附件(客户文件原件), 与报价读范围一致。
 */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class SalesQuoteAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "SALES_QUOTE";
    private final EntityManager em;
    private final SalesDocumentAccessPolicy access;
    private final SalesPriceMasker prices;

    @Override public String ownerType() { return OWNER_TYPE; }
    @Override public void requireCanView(UUID ownerId, AuthUser user) { readable(document(ownerId), user); }
    @Override public void requireCanViewSensitiveOriginal(UUID ownerId,AuthUser user) {
        SalesQuote quote=document(ownerId);readable(quote,user);
        if(has(user,SalesQuoteService.FINANCE_VIEW)&&SalesQuoteService.financeVisible(quote))return;
        if(!prices.canView())throw new ApiException(ErrorCode.FORBIDDEN,"识别原文件可能包含商业金额，需要订货价格查看权限");
    }
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

    private SalesQuote document(UUID id) { return document(id, false); }

    private SalesQuote document(UUID id, boolean includeDeleted) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定销售报价单");
        SalesQuote document = em.find(SalesQuote.class, id);
        if (document == null || (!includeDeleted && document.isDeleted())) throw missing();
        return document;
    }
    private void readable(SalesQuote document, AuthUser user) { readable(document,user,false); }

    private void readable(SalesQuote document, AuthUser user, boolean includeDeleted) {
        if ((!includeDeleted && document.isDeleted())) throw missing();
        if (has(user, SalesQuoteService.FINANCE_VIEW) && SalesQuoteService.financeVisible(document,includeDeleted)) return;
        if (!has(user, "sales_quote:view")) throw missing();
        access.requireReadable(document.getMakerId(), "销售报价单不存在");
    }

    /** 管理附件必须是负责人本人的读范围(核价人的只读放行不延伸到增删)。 */
    private void ownerReadable(SalesQuote document, AuthUser user) {
        if (document.isDeleted() || !has(user, "sales_quote:view")) throw missing();
        access.requireReadable(document.getMakerId(), "销售报价单不存在");
    }
    private void editable(SalesQuote document, AuthUser user) {
        ownerReadable(document, user);
        if (!has(user, "sales_quote:edit")) throw new ApiException(ErrorCode.FORBIDDEN, "缺少销售报价单编辑权限");
        access.requireWritable(document.getMakerId(), "无权修改该销售报价单附件");
        if (document.getStatus() == null || document.getStatus() != 0 || document.isClosed()) {
            throw new ApiException(ErrorCode.CONFLICT, "仅未关闭的草稿销售报价单可修改附件，提交核价后原件只读");
        }
    }
    private static boolean has(AuthUser user, String permission) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(permission));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在"); }

    @Override public void requireCanViewHistory(UUID ownerId, AuthUser user) {
        readable(document(ownerId,true),user,true);
    }
    @Override public void requireCanViewSensitiveOriginalHistory(UUID ownerId, AuthUser user) {
        SalesQuote quote=document(ownerId,true);readable(quote,user,true);
        if(has(user,SalesQuoteService.FINANCE_VIEW)&&SalesQuoteService.financeVisible(quote,true))return;
        if(!prices.canView())throw new ApiException(ErrorCode.FORBIDDEN,"识别原文件可能包含商业金额，需要订货价格查看权限");
    }
}
