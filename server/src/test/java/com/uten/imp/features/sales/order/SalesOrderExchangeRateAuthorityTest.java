package com.uten.imp.features.sales.order;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesMasterReferenceValidator;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.quote.SalesQuote;
import com.uten.imp.features.sales.quote.SalesQuoteItemRepository;
import com.uten.imp.features.sales.quote.SalesQuoteRepository;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SalesOrderExchangeRateAuthorityTest {

    @Mock private SalesOrderRepository orderRepo;
    @Mock private SalesOrderItemRepository itemRepo;
    @Mock private SalesOrderCostItemRepository costItemRepo;
    @Mock private StockReservationService reservationService;
    @Mock private PlanOrderItemLinkRepository linkRepo;
    @Mock private SalesQuoteRepository quoteRepo;
    @Mock private SalesQuoteItemRepository quoteItemRepo;
    @Mock private SalesPriceMasker priceMasker;
    @Mock private SalesDocumentAccessPolicy accessPolicy;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private EmployeeNameResolver nameResolver;
    @Mock private TxSessionVars tx;
    @Mock private DocNumberService docNumberService;
    @Mock private EntityManager em;
    @Mock private SalesOrderPlanProgressQuery planProgressQuery;
    @Mock private ChainNoticeService chainNotice;
    @Mock private AuditService auditService;
    @Mock private SalesMasterReferenceValidator referenceValidator;
    @Mock private TaskClaimService taskClaim;

    @InjectMocks private SalesOrderService service;

    private final UUID makerId = UUID.randomUUID();

    @Test
    void createIgnoresForgedRequestRateAndUsesActiveCurrencyMasterRate() {
        UUID currencyId = UUID.randomUUID();
        when(currentUser.requireEmployeeId()).thenReturn(makerId);
        when(docNumberService.nextNumber(DocNumberPrefix.SALES_ORDER))
                .thenReturn("XD202608080001");
        stubActiveCurrencyRate(currencyId, "7.200000");
        when(priceMasker.canView()).thenReturn(true);
        OrderSaveRequest request = request(currencyId, "999999");

        var detail = service.create(request);

        assertThat(detail.getExchangeRate()).isEqualByComparingTo("7.200000");
        assertThat(detail.getItems().get(0).getAmountOriginal())
                .isEqualByComparingTo("20.0000");
        assertThat(detail.getItems().get(0).getAmountLocal())
                .isEqualByComparingTo("144.0000");
    }

    @Test
    void sameCurrencyUpdatePreservesStoredRateSnapshot() {
        UUID currencyId = UUID.randomUUID();
        SalesOrder order = editableOrder(currencyId, "6.800000");
        prepareUpdate(order);
        when(priceMasker.canView()).thenReturn(true);
        OrderSaveRequest request = request(currencyId, "999999");

        var detail = service.update(order.getId(), request);

        assertThat(detail.getExchangeRate()).isEqualByComparingTo("6.800000");
        assertThat(detail.getItems().get(0).getAmountLocal())
                .isEqualByComparingTo("136.0000");
        verify(em, never()).createNativeQuery(contains("SELECT currency.exchange_rate"));
    }

    @Test
    void currencyChangeIgnoresRequestRateAndUsesNewCurrencyMasterRate() {
        UUID oldCurrencyId = UUID.randomUUID();
        UUID newCurrencyId = UUID.randomUUID();
        SalesOrder order = editableOrder(oldCurrencyId, "6.800000");
        prepareUpdate(order);
        stubActiveCurrencyRate(newCurrencyId, "7.400000");
        when(priceMasker.canView()).thenReturn(true);
        OrderSaveRequest request = request(newCurrencyId, "999999");

        var detail = service.update(order.getId(), request);

        assertThat(detail.getExchangeRate()).isEqualByComparingTo("7.400000");
        assertThat(detail.getItems().get(0).getAmountLocal())
                .isEqualByComparingTo("148.0000");
        verify(em).createNativeQuery(contains("SELECT currency.exchange_rate"));
    }

    @Test
    void createRejectsNonPositiveMasterRateEvenWhenRequestRateIsPositive() {
        UUID currencyId = UUID.randomUUID();
        when(docNumberService.nextNumber(DocNumberPrefix.SALES_ORDER))
                .thenReturn("XD202608080002");
        stubActiveCurrencyRate(currencyId, "0");
        OrderSaveRequest request = request(currencyId, "7.2");

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("参考汇率必须大于 0");
    }

    @Test
    void approvalRejectsStoredOrderWithoutCurrency() {
        SalesOrder order = editableOrder(null, "1");
        prepareUpdate(order);
        SalesOrderItem item = new SalesOrderItem();
        item.setOrderId(order.getId());
        item.setLineNo(1);
        Query itemLockQuery = mock(Query.class);
        when(em.createNativeQuery(contains("FROM sales_order_items")))
                .thenReturn(itemLockQuery);
        when(itemLockQuery.setParameter("orderId", order.getId()))
                .thenReturn(itemLockQuery);
        when(itemLockQuery.getResultList()).thenReturn(List.of(item.getId()));
        when(em.find(SalesOrderItem.class, item.getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(item);

        assertThatThrownBy(() -> service.approve(order.getId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("订单币种不能为空");
    }

    @Test
    void quoteConversionWithoutCurrencyUsesUniqueActiveCnyMaster() {
        UUID currencyId = UUID.randomUUID();
        UUID quoteOwner = UUID.randomUUID();
        Query cnyQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM")))
                .thenReturn(cnyQuery);
        when(cnyQuery.getResultList()).thenReturn(List.of(currencyId));
        stubActiveCurrencyRate(currencyId, "7.200000");
        when(currentUser.requireEmployeeId()).thenReturn(makerId);
        when(docNumberService.nextNumber(DocNumberPrefix.SALES_ORDER))
                .thenReturn("XD202608080003");
        when(priceMasker.canView()).thenReturn(true);
        SalesQuote source = new SalesQuote();
        source.setBillNo("XB202608080001");
        source.setMakerId(quoteOwner);
        when(quoteRepo.findByBillNo(source.getBillNo())).thenReturn(Optional.of(source));
        when(accessPolicy.hasAuthority("sales_quote:view")).thenReturn(true);
        OrderSaveRequest request = request(null, "999999");
        request.setSourceDocNo(source.getBillNo());

        var detail = service.createFromQuote(request, quoteOwner);

        assertThat(detail.getCurrencyId()).isEqualTo(currencyId);
        assertThat(detail.getExchangeRate()).isEqualByComparingTo("7.200000");
    }

    @Test
    void quoteConversionFallsBackToUniqueRenminbiNameWhenNoCnyCodeExists() {
        UUID currencyId = UUID.randomUUID();
        UUID quoteOwner = UUID.randomUUID();
        Query codeQuery = mock(Query.class);
        Query nameQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM")))
                .thenReturn(codeQuery);
        when(em.createNativeQuery(contains("BTRIM(COALESCE(name")))
                .thenReturn(nameQuery);
        when(codeQuery.getResultList()).thenReturn(List.of());
        when(nameQuery.getResultList()).thenReturn(List.of(currencyId));
        stubActiveCurrencyRate(currencyId, "7.200000");
        when(currentUser.requireEmployeeId()).thenReturn(makerId);
        when(docNumberService.nextNumber(DocNumberPrefix.SALES_ORDER))
                .thenReturn("XD202608080004");
        when(priceMasker.canView()).thenReturn(true);
        SalesQuote source = new SalesQuote();
        source.setBillNo("XB202608080002");
        source.setMakerId(quoteOwner);
        when(quoteRepo.findByBillNo(source.getBillNo())).thenReturn(Optional.of(source));
        when(accessPolicy.hasAuthority("sales_quote:view")).thenReturn(true);
        OrderSaveRequest request = request(null, "999999");
        request.setSourceDocNo(source.getBillNo());

        var detail = service.createFromQuote(request, quoteOwner);

        assertThat(detail.getCurrencyId()).isEqualTo(currencyId);
        assertThat(detail.getExchangeRate()).isEqualByComparingTo("7.200000");
    }

    @Test
    void quoteConversionFailsWhenNoActiveCnyOrRenminbiMasterExists() {
        Query codeQuery = mock(Query.class);
        Query nameQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM")))
                .thenReturn(codeQuery);
        when(em.createNativeQuery(contains("BTRIM(COALESCE(name")))
                .thenReturn(nameQuery);
        when(codeQuery.getResultList()).thenReturn(List.of());
        when(nameQuery.getResultList()).thenReturn(List.of());
        OrderSaveRequest request = request(null, "7.2");

        assertThatThrownBy(() -> service.createFromQuote(request, UUID.randomUUID()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("唯一启用的人民币币种");
    }

    @Test
    void quoteConversionFailsWhenMultipleActiveCnyMastersExist() {
        Query codeQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM")))
                .thenReturn(codeQuery);
        when(codeQuery.getResultList()).thenReturn(
                List.of(UUID.randomUUID(), UUID.randomUUID()));
        OrderSaveRequest request = request(null, "7.2");

        assertThatThrownBy(() -> service.createFromQuote(request, UUID.randomUUID()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("多条启用的 CNY");
    }

    @Test
    void quoteConversionFailsWhenMultipleRenminbiNameMastersExist() {
        Query codeQuery = mock(Query.class);
        Query nameQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM")))
                .thenReturn(codeQuery);
        when(em.createNativeQuery(contains("BTRIM(COALESCE(name")))
                .thenReturn(nameQuery);
        when(codeQuery.getResultList()).thenReturn(List.of());
        when(nameQuery.getResultList()).thenReturn(
                List.of(UUID.randomUUID(), UUID.randomUUID()));
        OrderSaveRequest request = request(null, "7.2");

        assertThatThrownBy(() -> service.createFromQuote(request, UUID.randomUUID()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("多条启用的人民币");
    }

    private void prepareUpdate(SalesOrder order) {
        when(orderRepo.findById(order.getId())).thenReturn(Optional.of(order));
        when(em.find(SalesOrder.class, order.getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
    }

    private SalesOrder editableOrder(UUID currencyId, String exchangeRate) {
        SalesOrder order = new SalesOrder();
        order.setBillNo("XD202608070001");
        order.setBillDate(LocalDate.of(2026, 8, 7));
        order.setClientId(UUID.randomUUID());
        order.setCurrencyId(currencyId);
        order.setExchangeRate(new BigDecimal(exchangeRate));
        order.setTaxRate(BigDecimal.ZERO);
        order.setOwnerEmployeeId(makerId);
        order.setStatus((short) 0);
        return order;
    }

    private void stubActiveCurrencyRate(UUID currencyId, String exchangeRate) {
        Query rateQuery = mock(Query.class);
        when(em.createNativeQuery(contains("SELECT currency.exchange_rate")))
                .thenReturn(rateQuery);
        when(rateQuery.setParameter("currencyId", currencyId)).thenReturn(rateQuery);
        when(rateQuery.getResultList())
                .thenReturn(List.of(new BigDecimal(exchangeRate)));
    }

    private static OrderSaveRequest request(UUID currencyId, String forgedRate) {
        OrderSaveRequest request = new OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 8));
        request.setClientId(UUID.randomUUID());
        request.setCurrencyId(currencyId);
        request.setExchangeRate(new BigDecimal(forgedRate));
        request.setTaxRate(BigDecimal.ZERO);

        OrderItemLine line = new OrderItemLine();
        line.setGoodsId(UUID.randomUUID());
        line.setUnitId(UUID.randomUUID());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("2"));
        line.setPrice(new BigDecimal("10"));
        line.setDiscount(BigDecimal.ONE);
        request.setItems(List.of(line));
        return request;
    }
}
