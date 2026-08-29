package com.uten.imp.features.production.schedule;

import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionScheduleNeedTest {

    @Test
    void partialShipmentAndPartialInboundLeaveOnlyUncoveredOutstanding() {
        assertThat(ProductionScheduleService.schedulingNeed(
                bd("100"), bd("20"), bd("0"), bd("0"),
                bd("30"), bd("70"), bd("30")))
                .isEqualByComparingTo("10");
    }

    @Test
    void returnIncreasesNeedAndFlagDecreasesNeed() {
        BigDecimal baseline = ProductionScheduleService.schedulingNeed(
                bd("100"), bd("20"), bd("0"), bd("0"),
                bd("30"), bd("70"), bd("30"));
        BigDecimal afterReturn = ProductionScheduleService.schedulingNeed(
                bd("100"), bd("20"), bd("8"), bd("0"),
                bd("30"), bd("70"), bd("30"));
        BigDecimal afterFlag = ProductionScheduleService.schedulingNeed(
                bd("100"), bd("20"), bd("0"), bd("6"),
                bd("30"), bd("70"), bd("30"));

        assertThat(afterReturn).isEqualByComparingTo(baseline.add(bd("8")));
        assertThat(afterFlag).isEqualByComparingTo(baseline.subtract(bd("6")));
    }

    @Test
    void producedQuantityIsNotDoubleCountedWhenFinishedStockIsReserved() {
        assertThat(ProductionScheduleService.schedulingNeed(
                bd("100"), bd("0"), bd("0"), bd("0"),
                bd("20"), bd("50"), bd("20")))
                .isEqualByComparingTo("50");
    }

    @Test
    void shortageBadgeIsZeroUntilAllocationBackedMrpIsAvailable() {
        EntityManager em = mock(EntityManager.class);
        MrpService mrp = mock(MrpService.class);
        when(mrp.isPlanningWriteReady()).thenReturn(false);
        ProductionScheduleService service = new ProductionScheduleService(
                em,
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mrp);

        assertThat(service.shortageCount()).isEqualTo(Map.of("count", 0L));
        verify(em, never()).createNativeQuery(org.mockito.ArgumentMatchers.anyString());
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
