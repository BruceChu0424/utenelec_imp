package com.uten.imp.common.columns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class BusinessColumnServiceTest {
    private final EntityManager em = mock(EntityManager.class);
    private final SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
    private final BusinessColumnService service = new BusinessColumnService(em, user, new ObjectMapper());

    @Test void similarNamesAreSuggestionsAfterExactAndContainedMatches() {
        var exact = suggestion("包装费", "ADD", 1, false);
        var contained = suggestion("额外包装费", "ADD", 5, false);
        var similar = suggestion("包装费用", "SUBTRACT", 100, true);
        var unrelated = suggestion("关税", "MULTIPLY", 999, true);
        assertThat(BusinessColumnService.rank(List.of(unrelated, similar, contained, exact), "包装费"))
                .extracting(BusinessColumnService.Definition::id)
                .containsExactly(exact.definition().id(), similar.definition().id(), contained.definition().id());
        // An empty query learns from explicit creation/use, without changing the operation.
        assertThat(BusinessColumnService.rank(List.of(unrelated, exact), "").getFirst().operation()).isEqualTo("MULTIPLY");
    }
    @Test void diceRecallsNearNamesThatAreNotSubstrings() {
        var near = suggestion("包装附加费用", "ADD", 1, false);
        assertThat(BusinessColumnService.rank(List.of(near), "包装费用")).containsExactly(near.definition());
    }
    private static BusinessColumnService.Suggestion suggestion(String name, String operation, long uses, boolean own) {
        return new BusinessColumnService.Suggestion(new BusinessColumnService.Definition(UUID.randomUUID(),
                "sales_order", name, "AMOUNT", operation, uses), own);
    }

    @Test void financeReadPermissionCannotWriteDefinitions() {
        permissions("finance:view:all");
        assertThatThrownBy(() -> service.create(new BusinessColumnService.Create("sales_order", "要求", "TEXT", "NONE")))
                .isInstanceOf(ApiException.class).hasMessageContaining("编辑");
        verifyNoInteractions(em);
    }
    @Test void amountWithoutOperationStillRequiresPricePermission() {
        permissions("sales_order:create");
        assertThatThrownBy(() -> service.create(new BusinessColumnService.Create("sales_order", "参考费用", "AMOUNT", "NONE")))
                .isInstanceOf(ApiException.class).hasMessageContaining("价格权限");
        assertThat(service.capabilities("sales_order").arithmetic()).isFalse();
        verifyNoInteractions(em);
    }
    @Test void officialAmountCapabilityRequiresTheSamePriceAuthorityAsDefinitionCreation() {
        for (String scope : List.of("sales_quote", "sales_order", "purchase_order", "subcontract_order")) {
            permissions(scope + ":view");
            assertThat(service.capabilities(scope).arithmetic()).as(scope + " view without prices").isFalse();
            permissions(scope + ":create", "goods:price:view");
            assertThat(service.capabilities(scope).arithmetic()).as(scope + " unrelated price permission").isFalse();
            String priceScope = "sales_quote".equals(scope) ? "sales_order" : scope;
            permissions(scope + ":create", priceScope + ":price:view");
            assertThat(service.capabilities(scope).arithmetic()).as(scope + " matching price permission").isTrue();
        }
        permissions("sales_quote:view", "sales_quote_finance:view");
        assertThat(service.capabilities("sales_quote").arithmetic()).isTrue();
        permissions("finance:view:all");
        assertThat(service.capabilities("purchase_order").arithmetic()).isTrue();
        verifyNoInteractions(em);
    }
    @Test void visitorCannotAcquireCommercialColumnCapabilitiesThroughStaffPermissionStrings() {
        when(user.get()).thenReturn(Optional.of(AuthUser.visitor(UUID.randomUUID(), "visitor", "V001",
                Set.of("sales_order:view", "sales_order:create", "sales_order:price:view", "finance:view:all"))));
        assertThatThrownBy(() -> service.capabilities("sales_order")).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.create(new BusinessColumnService.Create("sales_order", "运费", "AMOUNT", "ADD")))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(em);
    }
    @Test void omissionPreservesSnapshotAndEmptyArrayExplicitlyDeletes() {
        var prior = column("AMOUNT", "ADD", "8");
        assertThat(service.resolve("sales_order", null, List.of(prior), false)).containsExactly(prior);
        assertThat(service.resolve("sales_order", List.of(), List.of(prior), false)).isEmpty();
        verifyNoInteractions(em);
    }
    @Test void maskedSaveRestoresHiddenValueButCannotRemoveReorderOrChangeFees() {
        var first = column("AMOUNT", "ADD", "8");
        var second = column("NUMBER", "MULTIPLY", "2");
        definitions(first, second);
        var old = List.of(first, second);
        assertThat(service.resolve("sales_order", List.of(input(first, null), input(second, null)), old, true)).isEqualTo(old);
        assertThatThrownBy(() -> service.resolve("sales_order", List.of(), old, true)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.resolve("sales_order", List.of(input(second, null), input(first, null)), old, true))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.resolve("sales_order", List.of(input(first, "9"), input(second, null)), old, true))
                .isInstanceOf(ApiException.class);
        assertThat(BusinessColumnService.visible(old, true)).allSatisfy(c -> assertThat(c.value()).isNull());
    }
    @Test void rejectsDuplicateCrossScopeAndZeroDivisorBeforeAnUnpricedDraftCanSave() {
        var c = column("NUMBER", "DIVIDE", null);
        definitions(c);
        assertThatThrownBy(() -> service.resolve("sales_order", List.of(input(c, "0")), List.of(), false))
                .isInstanceOf(ApiException.class).hasMessageContaining("除以 0");
        assertThatThrownBy(() -> service.resolve("sales_order", List.of(input(c, "2"), input(c, "2")), List.of(), false))
                .isInstanceOf(ApiException.class).hasMessageContaining("重复");
        assertThatThrownBy(() -> service.resolve("purchase_order", List.of(input(c, "2")), List.of(), false))
                .isInstanceOf(ApiException.class).hasMessageContaining("不属于");
    }
    private void permissions(String... permissions) {
        when(user.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "test",
                Set.of(permissions), false, true, false)));
    }
    private void definitions(ExtraColumnSnapshot... columns) {
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(Arrays.stream(columns).map(c -> new Object[]{
                c.columnId(), "sales_order", c.name(), c.type(), c.operation(), 0L}).toList());
    }
    private static ExtraColumnSnapshot column(String type, String operation, String value) {
        return new ExtraColumnSnapshot(UUID.randomUUID(), "扩展条款", type, operation, value);
    }
    private static ExtraColumnInput input(ExtraColumnSnapshot c, String value) { return new ExtraColumnInput(c.columnId(), value); }
}
