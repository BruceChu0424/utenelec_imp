package com.uten.imp.common.pricing;

import com.uten.imp.application.port.ProcurementPriceAssessmentPort;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class ProcurementPriceAssessmentSupportTest {
    @SuppressWarnings("unchecked")
    private final ObjectProvider<ProcurementPriceAssessmentPort> provider = mock(ObjectProvider.class);
    private final ProcurementPriceAssessmentPort port = mock(ProcurementPriceAssessmentPort.class);
    private final ProcurementPriceAssessmentSupport support = new ProcurementPriceAssessmentSupport(provider);
    private final ProcurementPriceAssessmentPort.Request request = new ProcurementPriceAssessmentPort.Request("PURCHASE", null, List.of());

    @Test void missingPermissionDoesNotQueryHistoricalPrices() {
        when(provider.getIfAvailable()).thenReturn(port);
        when(port.available("PURCHASE")).thenReturn(false);
        assertThat(support.assess(request).status()).isEqualTo("UNAVAILABLE");
        verify(port, never()).assess(any());
    }
    @Test void adviceFailureDoesNotTurnASavedOrderIntoAnUnknownSaveResult() {
        when(provider.getIfAvailable()).thenReturn(port);
        when(port.available("PURCHASE")).thenReturn(true);
        when(port.assess(request)).thenThrow(new IllegalStateException("sensitive source unavailable"));
        var result = support.assess(request);
        assertThat(result.status()).isEqualTo("UNAVAILABLE");
        assertThat(result.items()).isEmpty();
    }
    @Test void publishedAssessmentUsesTheSameServerResultWithoutChangingMoney() {
        when(provider.getIfAvailable()).thenReturn(port);
        when(port.available("PURCHASE")).thenReturn(true);
        var assessed = new ProcurementPriceAssessmentPort.Assessment("CHECKED", null, List.of(
                new ProcurementPriceAssessmentPort.Warning("line", "HIGH", "10", "10.1", "15", "50", "500", 8, "SUFFICIENT", "请核对批量")));
        when(port.assess(request)).thenReturn(assessed);
        assertThat(support.assess(request)).isSameAs(assessed);
    }
}
