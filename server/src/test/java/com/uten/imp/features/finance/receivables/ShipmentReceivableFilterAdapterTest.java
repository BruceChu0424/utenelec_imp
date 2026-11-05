package com.uten.imp.features.finance.receivables;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.criteria.*;
import org.junit.jupiter.api.Test;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@SuppressWarnings("unchecked")
class ShipmentReceivableFilterAdapterTest {
    final ShipmentReceivableFilterAdapter adapter=new ShipmentReceivableFilterAdapter();
    @Test void invalidRangeCannotSilentlyBroadenAnAuthorizedQuery(){
        CriteriaBuilder builder=mock(CriteriaBuilder.class);
        CriteriaQuery<?> query=mock(CriteriaQuery.class);
        Expression<UUID> shipment=mock(Expression.class);
        assertThatThrownBy(()->adapter.predicate(builder,query,shipment,"OPEN OR 1=1"))
                .isInstanceOf(ApiException.class).hasMessageContaining("有效的出货收款范围");
        verifyNoInteractions(builder,query,shipment);
    }
    @Test void absentRangePreservesTheExistingOwnerAndDatePredicates(){
        CriteriaBuilder builder=mock(CriteriaBuilder.class);
        CriteriaQuery<?> query=mock(CriteriaQuery.class);
        Expression<UUID> shipment=mock(Expression.class);
        Predicate unchanged=mock(Predicate.class);when(builder.conjunction()).thenReturn(unchanged);
        assertThat(adapter.predicate(builder,query,shipment,"  ")).isSameAs(unchanged);
        verifyNoInteractions(query,shipment);
    }
}
