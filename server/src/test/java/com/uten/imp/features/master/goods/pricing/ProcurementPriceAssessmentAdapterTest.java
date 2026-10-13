package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.ProcurementPriceAssessmentPort;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ProcurementPriceAssessmentAdapterTest {
    @Test void oneHundredAndOneRowsAreAllAssessedInBoundedBatches(){
        var prices=mock(GoodsPriceAnalysisService.class);when(prices.available(Kind.PURCHASE)).thenReturn(true);
        when(prices.check(any())).thenAnswer(invocation->{
            CheckRequest r=invocation.getArgument(0);
            return new CheckResult(r.items().stream().map(i->new CheckRow(i.rowKey(),i.goodsId(),"READY","NONE","10","10","10","0","0",List.of(),"checked","evidence",3,"REFERENCE_ONLY",null,null)).toList(),"test",OffsetDateTime.now());
        });
        List<ProcurementPriceAssessmentPort.Line> lines=new ArrayList<>();for(int i=0;i<101;i++)lines.add(line(Integer.toString(i)));
        UUID excluded=UUID.randomUUID();var result=new ProcurementPriceAssessmentAdapter(prices).assess(new ProcurementPriceAssessmentPort.Request("PURCHASE",excluded,lines));
        assertThat(result.status()).isEqualTo("CHECKED");assertThat(result.items()).hasSize(101);assertThat(result.items()).extracting(ProcurementPriceAssessmentPort.Warning::rowKey).doesNotHaveDuplicates();
        var requests=ArgumentCaptor.forClass(CheckRequest.class);verify(prices,times(2)).check(requests.capture());
        assertThat(requests.getAllValues()).extracting(r->r.items().size()).containsExactly(100,1);assertThat(requests.getAllValues()).allMatch(r->excluded.equals(r.excludeOrderId()));
    }
    @Test void aDuplicateAcrossBatchBoundaryIsRejectedBeforeAnyPartialChecks(){
        var prices=mock(GoodsPriceAnalysisService.class);when(prices.available(Kind.PURCHASE)).thenReturn(true);
        List<ProcurementPriceAssessmentPort.Line> lines=new ArrayList<>();for(int i=0;i<100;i++)lines.add(line(Integer.toString(i)));lines.add(line("0"));
        assertThatThrownBy(()->new ProcurementPriceAssessmentAdapter(prices).assess(new ProcurementPriceAssessmentPort.Request("PURCHASE",null,lines))).hasMessageContaining("唯一行标识");
        verify(prices,never()).check(any());
    }
    private static ProcurementPriceAssessmentPort.Line line(String key){return new ProcurementPriceAssessmentPort.Line(key,UUID.randomUUID(),UUID.randomUUID(),null,UUID.randomUUID(),UUID.randomUUID(),BigDecimal.ZERO,BigDecimal.ONE,BigDecimal.TEN,null,false,BigDecimal.ONE,BigDecimal.ZERO);}
}
