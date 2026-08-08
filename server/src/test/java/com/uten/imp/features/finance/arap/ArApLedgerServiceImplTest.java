package com.uten.imp.features.finance.arap;

import com.uten.imp.features.finance.arap.ArApLedgerService.ArApPostingRequest;
import com.uten.imp.features.finance.arap.ArApLedgerService.SourceRef;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ArApLedgerServiceImplTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void postingPersistsOriginalCurrencyMetadataAndOneToManySourceSnapshots() {
        ArApLedgerRepository ledgerRepo = mock(ArApLedgerRepository.class);
        ArApSourceRefRepository sourceRefRepo = mock(ArApSourceRefRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        ArApLedgerServiceImpl service = new ArApLedgerServiceImpl(ledgerRepo, sourceRefRepo, tx);

        UUID shipmentId = UUID.randomUUID();
        UUID clientId = UUID.randomUUID();
        UUID currencyId = UUID.randomUUID();
        UUID orderOne = UUID.randomUUID();
        UUID orderTwo = UUID.randomUUID();
        when(ledgerRepo.findBySourceForUpdate(shipmentId, "SALES_SHIPMENT"))
                .thenReturn(List.of());

        service.postArAp(new ArApPostingRequest(
                "AR", "SALES_SHIPMENT", shipmentId, "XC26080001",
                LocalDate.of(2026, 8, 8), clientId, null, currencyId,
                new BigDecimal("7.000000"), new BigDecimal("700.0000"),
                (short) 3, "two orders", new BigDecimal("100.0000"),
                LocalDate.of(2026, 9, 7), (short) 6,
                List.of(
                        new SourceRef(SourceRef.SALES_ORDER, orderOne, "XD26080001",
                                new BigDecimal("40.0000"), new BigDecimal("280.0000")),
                        new SourceRef(SourceRef.SALES_ORDER, orderTwo, "XD26080002",
                                new BigDecimal("60.0000"), new BigDecimal("420.0000")))));

        ArgumentCaptor<ArApLedger> ledgerCaptor = ArgumentCaptor.forClass(ArApLedger.class);
        verify(ledgerRepo).save(ledgerCaptor.capture());
        ArApLedger ledger = ledgerCaptor.getValue();
        assertThat(ledger.getAmountOriginal()).isEqualByComparingTo("100.0000");
        assertThat(ledger.getAmountOriginalLocal()).isEqualByComparingTo("700.0000");
        assertThat(ledger.getAmountReceivedOriginal()).isZero();
        assertThat(ledger.getAmountReceivedLocal()).isZero();
        assertThat(ledger.getAmountWriteOffOriginal()).isZero();
        assertThat(ledger.getAmountWriteOffLocal()).isZero();
        assertThat(ledger.getAmountBalanceOriginal()).isEqualByComparingTo("100.0000");
        assertThat(ledger.getDueDate()).isEqualTo(LocalDate.of(2026, 9, 7));
        assertThat(ledger.getSettlementStyleLegacy()).isEqualTo((short) 6);

        ArgumentCaptor<Iterable> refsCaptor = ArgumentCaptor.forClass(Iterable.class);
        verify(sourceRefRepo).saveAll(refsCaptor.capture());
        List<ArApSourceRef> refs = ((Iterable<ArApSourceRef>) refsCaptor.getValue())
                .iterator().hasNext()
                ? ((List<ArApSourceRef>) refsCaptor.getValue())
                : List.of();
        assertThat(refs).hasSize(2);
        assertThat(refs).extracting(ArApSourceRef::getSourceNo)
                .containsExactly("XD26080001", "XD26080002");
        assertThat(refs).allMatch(ref -> ref.getLedgerId().equals(ledger.getId()));
    }

    @Test
    void sourceSnapshotAmountsMustReconcileToThePosting() {
        ArApLedgerRepository ledgerRepo = mock(ArApLedgerRepository.class);
        ArApSourceRefRepository sourceRefRepo = mock(ArApSourceRefRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        ArApLedgerServiceImpl service = new ArApLedgerServiceImpl(ledgerRepo, sourceRefRepo, tx);
        UUID sourceId = UUID.randomUUID();
        when(ledgerRepo.findBySourceForUpdate(sourceId, "SALES_SHIPMENT"))
                .thenReturn(List.of());

        ArApPostingRequest request = new ArApPostingRequest(
                "AR", "SALES_SHIPMENT", sourceId, "XC26080002",
                LocalDate.of(2026, 8, 8), UUID.randomUUID(), null, UUID.randomUUID(),
                BigDecimal.ONE, new BigDecimal("100.0000"), (short) 3, null,
                new BigDecimal("100.0000"), null, null,
                List.of(new SourceRef(SourceRef.SALES_ORDER, UUID.randomUUID(), "XD26080003",
                        new BigDecimal("99.0000"), new BigDecimal("100.0000"))));

        assertThatThrownBy(() -> service.postArAp(request))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("source ref amounts");
        verify(ledgerRepo, never()).save(any());
        verify(sourceRefRepo, never()).saveAll(any());
    }
}
