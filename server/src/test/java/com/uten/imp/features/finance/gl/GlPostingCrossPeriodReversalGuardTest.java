package com.uten.imp.features.finance.gl;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class GlPostingCrossPeriodReversalGuardTest {

    @Test
    void apPaymentAndSupplierClaimReversalsFailClosedAcrossPeriodsBeforeAnySqlMutation() {
        EntityManager em = mock(EntityManager.class);
        GlPostingService service = new GlPostingService(em, mock(TxSessionVars.class));
        LocalDate priorPeriodDate = BusinessTime.today().minusMonths(1);

        assertThatThrownBy(() -> service.removeAutoProjection(
                "AP_POST", "PURCHASE_RECEIPT", UUID.randomUUID(),
                "CGR-CROSS-PERIOD", priorPeriodDate))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("跨会计期间红冲");
        assertThatThrownBy(() -> service.removeAutoProjection(
                "AP_POST", "SUBCONTRACT_RECEIPT", UUID.randomUUID(),
                "WGR-CROSS-PERIOD", priorPeriodDate))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("跨会计期间红冲");
        assertThatThrownBy(() -> service.removePaymentDoc(
                UUID.randomUUID(), "CF-CROSS-PERIOD", priorPeriodDate))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("跨会计期间红冲");
        assertThatThrownBy(() -> service.removeAutoProjection(
                "SUPPLIER_CLAIM_LEDGER", "SUBCONTRACT_LOSS_OFFSET",
                UUID.randomUUID(), "SLC-CROSS-PERIOD", priorPeriodDate))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("跨会计期间红冲");
        assertThatThrownBy(() -> service.removeSupplierClaimOffsetBatch(
                UUID.randomUUID(), priorPeriodDate))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("跨会计期间红冲");
        assertThatThrownBy(() -> service.removeSupplierClaimReceivableDoc(
                UUID.randomUUID(), "SPCL-CROSS-PERIOD", priorPeriodDate))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("跨会计期间红冲");
        assertThatThrownBy(() -> service.removeSupplierClaimCashReceiptDoc(
                UUID.randomUUID(), "SPCR-CROSS-PERIOD", priorPeriodDate))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("跨会计期间红冲");

        verifyNoInteractions(em);
    }
}
