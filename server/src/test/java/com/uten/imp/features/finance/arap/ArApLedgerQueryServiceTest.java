package com.uten.imp.features.finance.arap;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.arap.dto.ArApLedgerListItem;
import com.uten.imp.features.finance.arap.dto.ArApLedgerQueryFilter;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ArApLedgerQueryServiceTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void listReturnsPartyCurrencySettlementAndAggregatedOrderMetadata() {
        ArApLedgerRepository repo = mock(ArApLedgerRepository.class);
        EntityManager em = mock(EntityManager.class);
        Query metadataQuery = mock(Query.class);
        ArApLedgerQueryService service = new ArApLedgerQueryService(repo, em);

        UUID ledgerId = UUID.randomUUID();
        UUID clientId = UUID.randomUUID();
        UUID currencyId = UUID.randomUUID();
        ArApLedger ledger = new ArApLedger();
        ledger.setId(ledgerId);
        ledger.setDirection("AR");
        ledger.setSourceDocType("SALES_SHIPMENT");
        ledger.setSourceDocId(UUID.randomUUID());
        ledger.setSourceDocNo("XC26080001");
        ledger.setBillNo("XC26080001");
        ledger.setBillDate(LocalDate.of(2026, 8, 8));
        ledger.setDueDate(LocalDate.of(2026, 9, 7));
        ledger.setClientId(clientId);
        ledger.setCurrencyId(currencyId);
        ledger.setExchangeRate(new BigDecimal("7.000000"));
        ledger.setAmountOriginal(new BigDecimal("100.0000"));
        ledger.setAmountOriginalLocal(new BigDecimal("700.0000"));
        ledger.setAmountReceivedOriginal(new BigDecimal("40.0000"));
        ledger.setAmountReceivedLocal(new BigDecimal("280.0000"));
        ledger.setAmountWriteOffOriginal(new BigDecimal("2.0000"));
        ledger.setAmountWriteOffLocal(new BigDecimal("14.0000"));
        ledger.setAmountBalanceOriginal(new BigDecimal("58.0000"));
        ledger.setAmountSettled(new BigDecimal("294.0000"));
        ledger.setAmountBalance(new BigDecimal("406.0000"));
        ledger.setSettlementStyleLegacy((short) 6);

        when(repo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(
                        List.of(ledger), PageRequest.of(0, 20), 1));
        when(em.createNativeQuery(anyString())).thenReturn(metadataQuery);
        when(metadataQuery.setParameter(eq("ledgerIds"), any()))
                .thenReturn(metadataQuery);
        when(metadataQuery.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{ledgerId, "测试客户", null, "USD", "美元",
                        "XD26080001\u001fXD26080002"}));

        ArApLedgerQueryFilter filter = new ArApLedgerQueryFilter(
                null, "AR", null, null, null, null,
                null, null, null, null, null, null);
        PageResponse<ArApLedgerListItem> result = service.list(
                filter, 0, 20, "billDate", "desc");

        assertThat(result.getItems()).hasSize(1);
        ArApLedgerListItem row = result.getItems().getFirst();
        assertThat(row.getClientName()).isEqualTo("测试客户");
        assertThat(row.getCurrencyCode()).isEqualTo("USD");
        assertThat(row.getCurrencyName()).isEqualTo("美元");
        assertThat(row.getExchangeRate()).isEqualByComparingTo("7.000000");
        assertThat(row.getAmountOriginal()).isEqualByComparingTo("100.0000");
        assertThat(row.getAmountReceivedOriginal()).isEqualByComparingTo("40.0000");
        assertThat(row.getAmountWriteOffOriginal()).isEqualByComparingTo("2.0000");
        assertThat(row.getAmountBalanceOriginal()).isEqualByComparingTo("58.0000");
        assertThat(row.getSettlementStyleLegacy()).isEqualTo((short) 6);
        assertThat(row.getDueDate()).isEqualTo(LocalDate.of(2026, 9, 7));
        assertThat(row.getSalesOrderNos())
                .containsExactly("XD26080001", "XD26080002");

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue()).contains("string_agg", "ar_ap_source_refs");
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void apKeepsLegacyLocalSettlementAndDoesNotInventOriginalCurrencySplit() {
        ArApLedgerRepository repo = mock(ArApLedgerRepository.class);
        EntityManager em = mock(EntityManager.class);
        Query metadataQuery = mock(Query.class);
        ArApLedgerQueryService service = new ArApLedgerQueryService(repo, em);

        UUID ledgerId = UUID.randomUUID();
        ArApLedger ledger = new ArApLedger();
        ledger.setId(ledgerId);
        ledger.setDirection("AP");
        ledger.setBillDate(LocalDate.of(2026, 8, 8));
        ledger.setAmountOriginal(new BigDecimal("100.0000"));
        ledger.setAmountOriginalLocal(new BigDecimal("700.0000"));
        ledger.setAmountSettled(new BigDecimal("280.0000"));
        ledger.setAmountBalance(new BigDecimal("420.0000"));
        // V236 initializes these receipt-only columns for every ledger row.
        // They are not authoritative for AP until FinancePaymentService is upgraded.
        ledger.setAmountReceivedLocal(BigDecimal.ZERO);
        ledger.setAmountWriteOffLocal(BigDecimal.ZERO);

        when(repo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(ledger), PageRequest.of(0, 20), 1));
        when(em.createNativeQuery(anyString())).thenReturn(metadataQuery);
        when(metadataQuery.setParameter(eq("ledgerIds"), any())).thenReturn(metadataQuery);
        when(metadataQuery.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{ledgerId, null, "测试供应商", "USD", "美元", ""}));

        ArApLedgerQueryFilter filter = new ArApLedgerQueryFilter(
                null, "AP", null, null, null, null,
                null, null, null, null, null, null);
        ArApLedgerListItem row = service.list(filter, 0, 20, "billDate", "desc")
                .getItems().getFirst();

        assertThat(row.getAmountReceivedLocal()).isEqualByComparingTo("280.0000");
        assertThat(row.getAmountWriteOffLocal()).isEqualByComparingTo("0");
        assertThat(row.getAmountReceivedOriginal()).isNull();
        assertThat(row.getAmountWriteOffOriginal()).isNull();
        assertThat(row.getAmountBalanceOriginal()).isNull();
    }
}
