package com.uten.imp.features.finance.arap;

import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ArApOffsetReverseGuardTest {

    @Test
    void sourcePostingCannotBeRemovedAfterAnyApprovedOffset() {
        ArApLedgerRepository ledgerRepo = mock(ArApLedgerRepository.class);
        ArApSourceRefRepository sourceRefRepo = mock(ArApSourceRefRepository.class);
        GlPostingService glPosting = mock(GlPostingService.class);
        ArApLedgerServiceImpl service = new ArApLedgerServiceImpl(
                ledgerRepo, sourceRefRepo, mock(TxSessionVars.class), glPosting,
                mock(com.uten.imp.features.finance.payables.SupplierClosedPeriodGuard.class));
        UUID sourceId = UUID.randomUUID();
        ArApLedger ledger = new ArApLedger();
        ledger.setDirection("AP");
        ledger.setBillNo("CJ26080001");
        ledger.setBillDate(LocalDate.of(2026, 8, 22));
        ledger.setAmountSettled(BigDecimal.ZERO);
        ledger.setAmountOffsetOriginal(new BigDecimal("10.0000"));
        ledger.setAmountOffsetLocal(new BigDecimal("70.0000"));
        when(ledgerRepo.findBySourceDocIdAndSourceDocTypeAndDeletedFalse(
                sourceId, "PURCHASE_RECEIPT")).thenReturn(List.of(ledger));
        when(ledgerRepo.findBySourceForUpdate(sourceId, "PURCHASE_RECEIPT"))
                .thenReturn(List.of(ledger));

        assertThatThrownBy(() -> service.reverseArAp(sourceId, "PURCHASE_RECEIPT"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("抵销");

        verify(glPosting).lockAutoProjectionPeriod(ledger.getBillDate());
        verify(glPosting, never()).removeAutoProjection(
                "AP_POST", "PURCHASE_RECEIPT", sourceId,
                ledger.getBillNo(), ledger.getBillDate());
        verify(ledgerRepo, never()).deleteAll(List.of(ledger));
        verify(ledgerRepo, never()).saveAll(List.of(ledger));
    }
}
