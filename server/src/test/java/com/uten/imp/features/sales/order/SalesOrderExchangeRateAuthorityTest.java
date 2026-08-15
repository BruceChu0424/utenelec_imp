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
import org.junit.jupiter.api.BeforeEach;
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
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.never;
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

    @BeforeEach
    void stubGoodsSnapshots() {
        Query goodsQuery = mock(Query.class);
        AtomicReference<List<UUID>> ids = new AtomicReference<>(List.of());
        lenient().when(em.createNativeQuery(contains("SELECT goods.id, goods.code, goods.name")))
                .thenReturn(goodsQuery);
        lenient().when(goodsQuery.setParameter(eq("ids"), any())).thenAnswer(invocation -> {
            @SuppressWarnings("unchecked")
            List<UUID> requested = invocation.getArgument(1);
            ids.set(requested);
            return goodsQuery;
        });
        lenient().when(goodsQuery.getResultList()).thenAnswer(invocation -> ids.get().stream()
                .map(id -> new Object[]{id, "HP000001", "测试货品"})
                .toList());
        // 订单详情的出货单聚合（V290 物流单号/SOP §三.7）：默认空聚合。
        Query shipmentsQuery = mock(Query.class);
        lenient().when(em.createNativeQuery(org.mockito.ArgumentMatchers.contains(
                "FROM sales_shipments s")))
                .thenReturn(shipmentsQuery);
        lenient().when(shipmentsQuery.setParameter(org.mockito.ArgumentMatchers.eq("orderId"),
                org.mockito.ArgumentMatchers.any()))
                .thenReturn(shipmentsQuery);
        lenient().when(shipmentsQuery.getResultList()).thenReturn(List.of());
    }

    @Test
    void createRequiresOnlyActiveCurrencyAndNeverReadsOrPersistsRate() {
        UUID currencyId = UUID.randomUUID();
        when(currentUser.requireEmployeeId()).thenReturn(makerId);
        when(docNumberService.nextNumber(DocNumberPrefix.SALES_ORDER))
                .thenReturn("XD202608080001");
        stubActiveCurrency(currencyId);
        when(priceMasker.canView()).thenReturn(true);

        var detail = service.create(request(currencyId, "999999"));

        assertThat(detail.getExchangeRate()).isNull();
        assertThat(detail.getTotalOriginal()).isEqualByComparingTo("20.0000");
        assertThat(detail.getTotalLocal()).isNull();
        assertThat(detail.getItems().getFirst().getAmountOriginal())
                .isEqualByComparingTo("20.0000");
        assertThat(detail.getItems().getFirst().getAmountLocal()).isNull();
        verify(em, never()).createNativeQuery(contains("currency.exchange_rate"));
    }

    @Test
    void sameCurrencyUpdateClearsLegacySalesStageRateAndLocalAmount() {
        UUID currencyId = UUID.randomUUID();
        SalesOrder order = editableOrder(currencyId, "6.8");
        prepareUpdate(order);
        stubActiveCurrency(currencyId);
        when(priceMasker.canView()).thenReturn(true);

        var detail = service.update(order.getId(), request(currencyId, "999999"));

        assertThat(detail.getExchangeRate()).isNull();
        assertThat(detail.getTotalLocal()).isNull();
        assertThat(detail.getItems().getFirst().getAmountLocal()).isNull();
        verify(em, never()).createNativeQuery(contains("currency.exchange_rate"));
    }

    @Test
    void currencyChangeValidatesTheNewCurrencyButStillLeavesRateNull() {
        UUID oldCurrencyId = UUID.randomUUID();
        UUID newCurrencyId = UUID.randomUUID();
        SalesOrder order = editableOrder(oldCurrencyId, "6.8");
        prepareUpdate(order);
        stubActiveCurrency(newCurrencyId);
        when(priceMasker.canView()).thenReturn(true);

        var detail = service.update(order.getId(), request(newCurrencyId, "999999"));

        assertThat(detail.getCurrencyId()).isEqualTo(newCurrencyId);
        assertThat(detail.getExchangeRate()).isNull();
        assertThat(detail.getItems().getFirst().getAmountLocal()).isNull();
    }

    @Test
    void approvalStillRejectsAnOrderWithoutCurrency() {
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
                .hasMessageContaining("币种");
    }

    @Test
    void quoteConversionResolvesActiveCnyButDoesNotCreateAnOrderRate() {
        UUID currencyId = UUID.randomUUID();
        UUID quoteOwner = UUID.randomUUID();
        Query cnyQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM"))).thenReturn(cnyQuery);
        when(cnyQuery.getResultList()).thenReturn(List.of(currencyId));
        stubActiveCurrency(currencyId);
        when(currentUser.requireEmployeeId()).thenReturn(makerId);
        when(docNumberService.nextNumber(DocNumberPrefix.SALES_ORDER))
                .thenReturn("XD202608080003");
        when(priceMasker.canView()).thenReturn(true);
        SalesQuote source = new SalesQuote();
        source.setBillNo("XB202608080001");
        source.setMakerId(quoteOwner);
        when(quoteRepo.findById(source.getId())).thenReturn(Optional.of(source));
        when(accessPolicy.hasAuthority("sales_quote:view")).thenReturn(true);
        OrderSaveRequest request = request(null, "999999");
        request.setSourceDocNo(source.getBillNo());

        var detail = service.createFromQuote(request, source.getId(), quoteOwner);

        assertThat(detail.getCurrencyId()).isEqualTo(currencyId);
        assertThat(detail.getExchangeRate()).isNull();
        assertThat(detail.getTotalLocal()).isNull();
    }

    @Test
    void quoteConversionFallsBackToUniqueRenminbiName() {
        UUID currencyId = UUID.randomUUID();
        UUID quoteOwner = UUID.randomUUID();
        Query codeQuery = mock(Query.class);
        Query nameQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM"))).thenReturn(codeQuery);
        when(em.createNativeQuery(contains("BTRIM(COALESCE(name"))).thenReturn(nameQuery);
        when(codeQuery.getResultList()).thenReturn(List.of());
        when(nameQuery.getResultList()).thenReturn(List.of(currencyId));
        stubActiveCurrency(currencyId);
        when(currentUser.requireEmployeeId()).thenReturn(makerId);
        when(docNumberService.nextNumber(DocNumberPrefix.SALES_ORDER))
                .thenReturn("XD202608080004");
        when(priceMasker.canView()).thenReturn(true);
        SalesQuote source = new SalesQuote();
        source.setBillNo("XB202608080002");
        source.setMakerId(quoteOwner);
        when(quoteRepo.findById(source.getId())).thenReturn(Optional.of(source));
        when(accessPolicy.hasAuthority("sales_quote:view")).thenReturn(true);
        OrderSaveRequest request = request(null, "999999");
        request.setSourceDocNo(source.getBillNo());

        var detail = service.createFromQuote(request, source.getId(), quoteOwner);

        assertThat(detail.getCurrencyId()).isEqualTo(currencyId);
        assertThat(detail.getExchangeRate()).isNull();
        assertThat(detail.getTotalLocal()).isNull();
    }

    @Test
    void quoteConversionFailsWhenNoActiveCnyOrRenminbiMasterExists() {
        Query codeQuery = mock(Query.class);
        Query nameQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM"))).thenReturn(codeQuery);
        when(em.createNativeQuery(contains("BTRIM(COALESCE(name"))).thenReturn(nameQuery);
        when(codeQuery.getResultList()).thenReturn(List.of());
        when(nameQuery.getResultList()).thenReturn(List.of());

        assertThatThrownBy(() -> service.createFromQuote(
                request(null, "7.2"), UUID.randomUUID(), UUID.randomUUID()))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void quoteConversionFailsWhenMultipleActiveCnyMastersExist() {
        Query codeQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM"))).thenReturn(codeQuery);
        when(codeQuery.getResultList()).thenReturn(
                List.of(UUID.randomUUID(), UUID.randomUUID()));

        assertThatThrownBy(() -> service.createFromQuote(
                request(null, "7.2"), UUID.randomUUID(), UUID.randomUUID()))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void quoteConversionFailsWhenMultipleRenminbiNameMastersExist() {
        Query codeQuery = mock(Query.class);
        Query nameQuery = mock(Query.class);
        when(em.createNativeQuery(contains("UPPER(BTRIM"))).thenReturn(codeQuery);
        when(em.createNativeQuery(contains("BTRIM(COALESCE(name"))).thenReturn(nameQuery);
        when(codeQuery.getResultList()).thenReturn(List.of());
        when(nameQuery.getResultList()).thenReturn(
                List.of(UUID.randomUUID(), UUID.randomUUID()));

        assertThatThrownBy(() -> service.createFromQuote(
                request(null, "7.2"), UUID.randomUUID(), UUID.randomUUID()))
                .isInstanceOf(ApiException.class);
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
        order.setTotalLocal(new BigDecimal("136"));
        order.setTaxRate(BigDecimal.ZERO);
        order.setOwnerEmployeeId(makerId);
        order.setStatus((short) 0);
        return order;
    }

    private void stubActiveCurrency(UUID currencyId) {
        Query currencyQuery = mock(Query.class);
        when(em.createNativeQuery(contains("SELECT currency.id")))
                .thenReturn(currencyQuery);
        when(currencyQuery.setParameter("currencyId", currencyId))
                .thenReturn(currencyQuery);
        when(currencyQuery.getResultList()).thenReturn(List.of(currencyId));
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
