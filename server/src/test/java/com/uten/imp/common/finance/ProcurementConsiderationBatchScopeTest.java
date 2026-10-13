package com.uten.imp.common.finance;

import com.uten.imp.application.port.ProcurementCreditBookAllocationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementConsiderationBatchScopeTest {
    @Test void twoStockItemsShareTheExactRemainingPassFundingWithoutReusingIt() {
        Fixture fixture=new Fixture();
        var first=fixture.input("0.4");var second=fixture.input("0.6");
        AtomicReference<ProcurementReceiptConsiderationService.StockInAllocationWriter> escaped=new AtomicReference<>();
        fixture.service.withStockInAllocations(List.of(first,second),writer->{
            escaped.set(writer);writer.settle(first.stockInItemId());writer.settle(second.stockInItemId());
        });
        assertThat(fixture.writes).hasSize(2);
        assertThat(fixture.writes).extracting(row->row.get("stock")).containsExactly(first.stockInItemId(),second.stockInItemId());
        assertThat(fixture.writes).allSatisfy(row->assertThat(row.get("quality")).isEqualTo(fixture.quality));
        assertThat((BigDecimal)fixture.writes.get(0).get("original")).isEqualByComparingTo("4");
        assertThat((BigDecimal)fixture.writes.get(1).get("original")).isEqualByComparingTo("6");
        assertThrows(ApiException.class,()->escaped.get().settle(first.stockInItemId()));
        assertThat(fixture.writes).hasSize(2);
    }

    @Test void aSwallowedSecondAllocationFailureCannotCompleteTheCommand() {
        Fixture fixture=new Fixture();
        var first=fixture.input("0.4");var overflow=fixture.input("0.7");
        assertThrows(ApiException.class,()->fixture.service.withStockInAllocations(List.of(first,overflow),writer->{
            writer.settle(first.stockInItemId());
            assertThrows(ApiException.class,()->writer.settle(overflow.stockInItemId()));
        }));
        assertThat(fixture.writes).hasSize(1);
    }

    private static final class Fixture {
        final UUID inspection=UUID.randomUUID(),pass=UUID.randomUUID(),quality=UUID.randomUUID(),part=UUID.randomUUID();
        final List<Map<String,Object>> writes=new ArrayList<>();
        final ProcurementReceiptConsiderationService service;
        Fixture(){
            EntityManager em=mock(EntityManager.class);
            SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
            when(current.requireId()).thenReturn(UUID.randomUUID());
            when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
                String sql=invocation.getArgument(0);Query query=mock(Query.class);
                Map<String,Object> parameters=new LinkedHashMap<>();
                when(query.setParameter(anyString(),any())).thenAnswer(binding->{
                    parameters.put(binding.getArgument(0),binding.getArgument(1));return query;
                });
                when(query.getSingleResult()).thenReturn(0L);
                if(sql.contains("quality.inspection_event_id IN")) {
                    when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{quality,part,
                            new BigDecimal("1.25"),new BigDecimal("12.5"),new BigDecimal("12.5"),
                            new BigDecimal("0.25"),"STANDARD",null,pass}));
                } else when(query.getResultList()).thenReturn(List.of());
                when(query.executeUpdate()).thenAnswer(write->{writes.add(new LinkedHashMap<>(parameters));return 1;});
                return query;
            });
            service=new ProcurementReceiptConsiderationService(em,current,mock(ProcurementCreditBookAllocationPort.class));
        }
        ProcurementReceiptConsiderationService.StockInInput input(String quantity){
            return new ProcurementReceiptConsiderationService.StockInInput(UUID.randomUUID(),inspection,pass,new BigDecimal(quantity));
        }
    }
}
