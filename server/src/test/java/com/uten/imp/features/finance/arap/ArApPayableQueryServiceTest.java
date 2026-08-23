package com.uten.imp.features.finance.arap;

import com.uten.imp.features.finance.arap.dto.ArApLedgerListItem;
import com.uten.imp.features.finance.arap.dto.ArApLedgerQueryFilter;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
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
import static org.mockito.Mockito.when;

class ArApPayableQueryServiceTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void payableExposesAuthoritativeOriginalCurrencyPaymentOffsetAndBalance() {
        ArApLedgerRepository repo = mock(ArApLedgerRepository.class);
        EntityManager em = mock(EntityManager.class);
        Query metadataQuery = mock(Query.class);
        ArApLedgerQueryService service = new ArApLedgerQueryService(repo, em);

        UUID ledgerId = UUID.randomUUID();
        ArApLedger ledger = new ArApLedger();
        ledger.setId(ledgerId);
        ledger.setDirection("AP");
        ledger.setBillNo("CJ26080001");
        ledger.setBillDate(LocalDate.of(2026, 8, 22));
        ledger.setAmountOriginal(new BigDecimal("100.0000"));
        ledger.setAmountOriginalLocal(new BigDecimal("700.0000"));
        ledger.setAmountReceivedOriginal(new BigDecimal("30.0000"));
        ledger.setAmountReceivedLocal(new BigDecimal("216.0000"));
        ledger.setAmountWriteOffOriginal(BigDecimal.ZERO);
        ledger.setAmountWriteOffLocal(BigDecimal.ZERO);
        ledger.setAmountOffsetOriginal(new BigDecimal("10.0000"));
        ledger.setAmountOffsetLocal(new BigDecimal("70.0000"));
        ledger.setAmountBalanceOriginal(new BigDecimal("60.0000"));
        ledger.setAmountSettled(new BigDecimal("210.0000"));
        ledger.setAmountBalance(new BigDecimal("420.0000"));

        when(repo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(ledger), PageRequest.of(0, 20), 1));
        when(em.createNativeQuery(anyString())).thenReturn(metadataQuery);
        when(metadataQuery.setParameter(eq("ledgerIds"), any())).thenReturn(metadataQuery);
        when(metadataQuery.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{ledgerId, null, "测试供应商", "USD", "美元", "", ""}));

        ArApLedgerListItem row = service.list(
                        new ArApLedgerQueryFilter(
                                null, "AP", null, null, null, null,
                                null, null, null, null, null, null),
                        0, 20, "billDate", "desc")
                .getItems().getFirst();

        assertThat(row.getAmountReceivedOriginal()).isEqualByComparingTo("30.0000");
        assertThat(row.getAmountReceivedLocal()).isEqualByComparingTo("216.0000");
        assertThat(row.getAmountOffsetOriginal()).isEqualByComparingTo("10.0000");
        assertThat(row.getAmountOffsetLocal()).isEqualByComparingTo("70.0000");
        assertThat(row.getAmountBalanceOriginal()).isEqualByComparingTo("60.0000");
    }
}
