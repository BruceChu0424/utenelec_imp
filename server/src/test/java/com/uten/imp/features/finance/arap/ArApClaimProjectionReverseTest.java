package com.uten.imp.features.finance.arap;

import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ArApClaimProjectionReverseTest {

    @Test
    void claimCreditReverseRemovesItsDedicatedProjectionAndRetainsLedgerHistory() {
        ArApLedgerRepository ledgerRepo = mock(ArApLedgerRepository.class);
        ArApSourceRefRepository sourceRefRepo = mock(ArApSourceRefRepository.class);
        GlPostingService glPosting = mock(GlPostingService.class);
        ArApLedgerServiceImpl service = new ArApLedgerServiceImpl(
                ledgerRepo, sourceRefRepo, mock(TxSessionVars.class), glPosting,
                mock(com.uten.imp.features.finance.payables.SupplierClosedPeriodGuard.class));
        UUID resolutionId = UUID.randomUUID();
        LocalDate claimDate = LocalDate.of(2026, 8, 22);
        ArApLedger ledger = new ArApLedger();
        ledger.setDirection("AP");
        ledger.setBillNo("EW202608220001-索赔抵销");
        ledger.setBillDate(claimDate);
        ledger.setAmountSettled(BigDecimal.ZERO);
        ledger.setAmountOffsetOriginal(BigDecimal.ZERO);
        ledger.setAmountOffsetLocal(BigDecimal.ZERO);
        when(ledgerRepo.findBySourceDocIdAndSourceDocTypeAndDeletedFalse(
                resolutionId, "SUBCONTRACT_LOSS_OFFSET")).thenReturn(List.of(ledger));
        when(ledgerRepo.findBySourceForUpdate(resolutionId, "SUBCONTRACT_LOSS_OFFSET"))
                .thenReturn(List.of(ledger));

        service.reverseArAp(resolutionId, "SUBCONTRACT_LOSS_OFFSET");

        verify(glPosting).removeAutoProjection(
                "SUPPLIER_CLAIM_LEDGER", "SUBCONTRACT_LOSS_OFFSET",
                resolutionId, ledger.getBillNo(), claimDate);
        verify(ledgerRepo).saveAll(List.of(ledger));
        assertThat(ledger.getStatus()).isEqualTo((short) -1);
        assertThat(ledger.isDeleted()).isTrue();
        assertThat(ledger.getDeletedAt()).isNotNull();
    }
}
