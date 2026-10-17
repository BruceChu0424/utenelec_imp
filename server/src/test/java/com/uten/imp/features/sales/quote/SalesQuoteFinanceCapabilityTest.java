package com.uten.imp.features.sales.quote;

import com.uten.imp.application.port.SalesQuoteFinanceReviewerEligibilityPort;
import com.uten.imp.application.port.SalesQuoteNoticePort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesPriceAuthority;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SalesQuoteFinanceCapabilityTest {
    @ParameterizedTest(name = "{0}")
    @MethodSource("goodsPriceMaintenanceAuthorities")
    void reviewOnlyAdvertisesExistingGoodsPriceMaintenanceWithBothWriteAuthorities(
            String scenario, Set<String> permissions, boolean superAdmin, boolean expected) {
        UUID id = UUID.randomUUID();
        SalesQuote quote = new SalesQuote();
        quote.setId(id);
        quote.setStatus((short) 2);
        EntityManager em = mock(EntityManager.class);
        Query header = mock(Query.class);
        Query lines = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(header, lines);
        when(header.setParameter("id", id)).thenReturn(header);
        when(header.getSingleResult()).thenReturn(new Object[]{"客户", "C01", "销售", "销售", "人民币",
                true, "现结", null, null, null});
        when(lines.setParameter("id", id)).thenReturn(lines);
        when(lines.getResultList()).thenReturn(List.of());
        SalesQuoteRepository quotesRepo = mock(SalesQuoteRepository.class);
        when(quotesRepo.findById(id)).thenReturn(Optional.of(quote));
        SalesQuoteService quotes = mock(SalesQuoteService.class);
        when(quotes.convertedOrders(List.of(id))).thenReturn(Map.of());
        SalesPriceAuthority prices = mock(SalesPriceAuthority.class);
        when(prices.resolveFileCurrency(null))
                .thenReturn(new SalesPriceAuthority.FileCurrency(null, true, BigDecimal.ONE));
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        AuthUser actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reviewer", permissions,
                false, true, superAdmin);
        when(current.get()).thenReturn(Optional.of(actor));
        SalesDocumentAccessPolicy access = new SalesDocumentAccessPolicy(mock(OwnerVisibility.class), current);
        SalesQuoteFinanceService service = new SalesQuoteFinanceService(em, quotesRepo,
                mock(SalesQuoteItemRepository.class), quotes, current, mock(TxSessionVars.class),
                mock(SalesQuoteFinanceReviewerEligibilityPort.class), mock(TaskClaimMutationGuardPort.class),
                mock(TaskClaimService.class), mock(SalesQuoteRevisionLog.class), mock(SalesQuoteNoticePort.class),
                prices, access);

        assertThat(service.review(id).canMaintainGoodsPrice()).as(scenario).isEqualTo(expected);
    }

    static Stream<Arguments> goodsPriceMaintenanceAuthorities() {
        return Stream.of(
                Arguments.of("field permission alone cannot edit an existing goods master",
                        Set.of("goods:view", "goods:price:edit"), false, false),
                Arguments.of("create with field permission cannot maintain an existing goods master",
                        Set.of("goods:view", "goods:create", "goods:price:edit"), false, false),
                Arguments.of("general goods edit cannot change prices without the field permission",
                        Set.of("goods:view", "goods:edit"), false, false),
                Arguments.of("general and field edit allow the existing goods maintenance entry",
                        Set.of("goods:view", "goods:edit", "goods:price:edit"), false, true),
                Arguments.of("the established super administrator authority is retained", Set.of(), true, true));
    }
}
