package com.uten.imp.features.sales.quote;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-134 报价附件: 核价人可只读查看待核价/已核价/本轮退回报价的客户文件原件(不论负责人),
 * 但不能增删; 提交后又撤回的草稿核价人看不到; 负责人只在草稿(含退回草稿)可管理附件。
 */
class SalesQuoteAttachmentFinanceReadTest {

    private final UUID id = UUID.randomUUID();
    private final UUID owner = UUID.randomUUID();
    private final EntityManager em = mock(EntityManager.class);
    private final SalesDocumentAccessPolicy access = mock(SalesDocumentAccessPolicy.class);
    private final SalesQuote quote = new SalesQuote();
    private final SalesQuoteAttachmentAccessPolicy policy = new SalesQuoteAttachmentAccessPolicy(em, access,mock(com.uten.imp.features.sales.order.SalesPriceMasker.class));

    SalesQuoteAttachmentFinanceReadTest() {
        quote.setId(id);
        quote.setMakerId(owner);
        when(em.find(SalesQuote.class, id)).thenReturn(quote);
        // 财务不在销售负责人范围: 负责人读范围一律拒绝。
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在"))
                .when(access).requireReadable(any(), anyString());
    }

    @Test
    void reviewerReadsSubmittedAndConfirmedQuotesButCannotManageThem() {
        AuthUser reviewer = user("sales_quote_finance:view", "attachment:view");
        quote.setStatus((short) 2);
        assertDoesNotThrow(() -> policy.requireCanView(id, reviewer));
        quote.setStatus((short) 1);
        // 旧流程销售自审的已审报价(没有财务确认时间)不在财务读范围。
        assertThrows(ApiException.class, () -> policy.requireCanView(id, reviewer));
        quote.setFinanceConfirmedAt(OffsetDateTime.now());
        assertDoesNotThrow(() -> policy.requireCanView(id, reviewer));
        assertThrows(ApiException.class, () -> policy.requireCanManage(id, reviewer));
        verify(access, never()).requireWritable(any(), anyString());
    }

    @Test
    void reviewerSeesAReturnedDraftButNotAWithdrawnOne() {
        AuthUser reviewer = user("sales_quote_finance:view");
        OffsetDateTime submitted = OffsetDateTime.now().minusHours(1);
        quote.setStatus((short) 0);
        quote.setSubmittedAt(submitted);
        quote.setFinanceReturnedAt(submitted.plusMinutes(5));
        quote.setFinanceReturnReason("缺货品需补充");
        assertDoesNotThrow(() -> policy.requireCanView(id, reviewer));

        quote.setFinanceReturnedAt(null);
        quote.setFinanceReturnReason(null);
        ApiException hidden = assertThrows(ApiException.class, () -> policy.requireCanView(id, reviewer));
        assertEquals(ErrorCode.NOT_FOUND, hidden.getCode());
    }

    @Test
    void ownerManagesAttachmentsOnlyWhileTheQuoteIsADraft() {
        SalesDocumentAccessPolicy ownerAccess = mock(SalesDocumentAccessPolicy.class);
        SalesQuoteAttachmentAccessPolicy ownerPolicy = new SalesQuoteAttachmentAccessPolicy(em, ownerAccess,mock(com.uten.imp.features.sales.order.SalesPriceMasker.class));
        AuthUser seller = user("sales_quote:view", "sales_quote:edit");
        quote.setStatus((short) 0);
        quote.setFinanceReturnReason("客户要改数量");
        assertDoesNotThrow(() -> ownerPolicy.requireCanManage(id, seller));
        quote.setStatus((short) 2);
        ApiException frozen = assertThrows(ApiException.class, () -> ownerPolicy.requireCanManage(id, seller));
        assertEquals(ErrorCode.CONFLICT, frozen.getCode());
    }

    @Test
    void deletedReturnedQuoteKeepsItsCurrentFinanceHistoryScopeButNotActiveActions() {
        AuthUser reviewer=user("sales_quote_finance:view");
        quote.setStatus((short)0);
        quote.setSubmittedAt(OffsetDateTime.now().minusHours(1));
        quote.setFinanceReturnedAt(OffsetDateTime.now());
        quote.setDeleted(true);
        assertDoesNotThrow(()->policy.requireCanViewSensitiveOriginalHistory(id,reviewer));
        assertThrows(ApiException.class,()->policy.requireCanView(id,reviewer));
        assertThrows(ApiException.class,()->policy.requireCanManage(id,reviewer));
        assertThrows(ApiException.class,()->policy.requireCanViewSensitiveOriginalHistory(id,user("sales_quote:view")));
        quote.setFinanceReturnedAt(null);
        assertThrows(ApiException.class,()->policy.requireCanViewSensitiveOriginalHistory(id,reviewer));
    }

    private static AuthUser user(String... permissions) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "tester", Set.of(permissions), false, true, false);
    }
}
