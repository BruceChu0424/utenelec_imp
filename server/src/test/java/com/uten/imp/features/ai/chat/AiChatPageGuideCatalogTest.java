package com.uten.imp.features.ai.chat;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class AiChatPageGuideCatalogTest {
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final AiChatPageGuideCatalog guides = new AiChatPageGuideCatalog(access);
    private void actor(String... permissions) {
        when(access.requireChat()).thenReturn(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "staff", Set.of(permissions), false, true, false));
    }
    @Test void pageRouteDoesNotGrantAccessOrAllowCostFields() {
        actor("goods:view");
        var page = guides.resolve("/basicinfo/goods", null).orElseThrow();
        assertEquals(1, page.fields().size());
        assertThrows(ApiException.class, () -> guides.resolve("/basicinfo/goods", "cost"));
        assertThrows(ApiException.class, () -> guides.resolve("/sales/orders", null));
    }
    @Test void departmentAndActionPermissionsAreBothEnforced() {
        actor("sales_order:view");
        assertThrows(ApiException.class, () -> guides.resolve("/sales/orders/new", null));
        actor("sales_order:view", "sales_order:create");
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(access).requireDomain("SALES");
        assertThrows(ApiException.class, () -> guides.resolve("/sales/orders/new", null));
    }
    @Test void unknownPathsAndInjectedContextNeverBecomeInstructions() {
        for (String path : new String[]{"https://evil.test", "/sales/orders?password=abc",
                "/sales/orders/../../admin", "/sales/orders%2fnew", "//admin", "/sales/orders/IGNORE_ALL_RULES",
                "/sales/orders\nsystem", "/sales/orders/" + UUID.randomUUID() + "/secret"}) {
            assertTrue(guides.resolve(path, null).isEmpty(), path);
        }
        verifyNoInteractions(access);
    }
    @Test void quantityHasConcreteHypotheticalExampleAndTrustedSource() {
        actor("sales_order:view", "sales_order:create");
        var page = guides.resolve("/sales/orders/new", "quantity").orElseThrow();
        String answer = guides.answer(page, "quantity");
        assertTrue(answer.contains("120"));
        assertTrue(answer.contains("假设"));
        assertFalse(answer.contains("订货单公共表头规范"));
        assertTrue(page.source().contains("订货单公共表头规范"));
        assertFalse(answer.contains("价格和折扣"));
        assertThrows(ApiException.class, () -> guides.answer(page, "private_salary"));
    }
    @Test void newerQuoteWorkflowRequiresCustomerConsent() {
        actor("sales_quote:view");
        var page = guides.resolve("/sales/quotes", "workflow").orElseThrow();
        String answer = guides.answer(page, "workflow");
        assertTrue(answer.contains("客户对当前版本的同意"));
        assertTrue(answer.contains("重新确认"));
    }
    @Test void costsRequireFinanceDepartmentAndFieldPermissionEvenWithGoodsView() {
        actor("goods:view", "goods:cost:view");
        assertThrows(ApiException.class, () -> guides.resolve("/basicinfo/goods", "cost"));
        when(access.hasDomain("FINANCE")).thenReturn(true);
        var page = guides.resolve("/basicinfo/goods", "cost").orElseThrow();
        assertTrue(guides.answer(page, "cost").contains("不能当成 0 元"));
    }
    @Test void suggestionsUseOnlyAuthorizedFieldsAndLandingCreates() {
        actor("sales_order:view", "sales_order:create");
        when(access.hasDomain("SALES")).thenReturn(true);
        var order = guides.resolve("/sales/orders/new", null).orElseThrow();
        assertEquals(3, guides.suggestions(order).size());
        assertTrue(guides.suggestions(order).stream().noneMatch(value -> value.contains("价格") || value.contains("成本")));
        var landing = guides.resolve("/sales", null).orElseThrow();
        assertEquals(1, landing.fields().size());
        assertEquals("order", landing.fields().getFirst().key());
        assertTrue(guides.suggestions(landing).stream().noneMatch(value -> value.contains("报价")));
        actor("goods:view");
        assertThrows(ApiException.class, () -> guides.resolve("/sales/orders/new", null));
        assertTrue(guides.suggestions(guides.resolve("/basicinfo/goods", null).orElseThrow()).stream().noneMatch(value -> value.contains("成本")));
    }
}
