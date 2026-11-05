package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ShelfLabelOutputScopeTest {
    @Test void printReadsBeyondFiveThousandWithoutDroppingPhysicalIdentities() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class);
        AtomicInteger offset=new AtomicInteger();
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenAnswer(call->{
            if("__offset".equals(call.getArgument(0))) offset.set(((Number)call.getArgument(1)).intValue());
            return query;
        });
        when(query.getResultList()).thenAnswer(call->java.util.stream.IntStream
                .range(offset.get(),Math.min(5001,offset.get()+500)).mapToObj(index->new Object[]{
                    new UUID(1,index+1),"A-2-1","C"+index,"系列","物料","红","个",BigDecimal.ONE,
                    false,true,new UUID(2,1),"A仓",new UUID(3,1),"WAREHOUSE_MASTER"
                }).toList());
        var rows=new StockQueryService(mock(StockBalanceRepository.class),em,mock(StockCostMasker.class))
                .shelfLabelRowsForOutput(null,null,null,false,Map.of());
        assertEquals(5001,rows.size());
        assertEquals(5001,rows.stream().map(row->row.getGoodsId()).distinct().count());
        assertEquals("C5000",rows.getLast().getGoodsCode());
        assertEquals(new UUID(2,1),rows.getLast().getWarehouseId());
        verify(query,times(11)).getResultList();
    }

    @Test void headerFiltersRunBeforePaginationAndUnparsedLevelsCannotCauseCasts() {
        String sql=ShelfLabelSql.rowsPage(true,true,false,false,Map.of("rack","A","level","2","status","启用"));
        assertTrue(sql.indexOf(":headerRack")<sql.indexOf("LIMIT :__limit"));
        assertTrue(sql.contains("CASE WHEN r.parsed THEN split_part(r.place,'-',2)::int END=:headerLevel"));
        assertTrue(sql.contains("r.disabled=:headerDisabled"));
        String unparsed=ShelfLabelSql.rowsPage(false,true,false,false,Map.of("rack","未分层"));
        assertTrue(unparsed.contains("AND NOT r.parsed"));
        assertFalse(unparsed.contains(":headerRack"));
        assertThrows(ApiException.class,()->StockQueryService.shelfHeaderFilters(Map.of("level","2 OR 1=1")));
        assertThrows(ApiException.class,()->StockQueryService.shelfHeaderFilters(Map.of("status","unknown")));
    }

    @Test void printAuthorityUsesAReadOnlyRepeatableReadSnapshot() throws Exception {
        var transaction=StockQueryService.class.getMethod("shelfLabelRowsForOutput",String.class,String.class,
                UUID.class,boolean.class,Map.class).getAnnotation(org.springframework.transaction.annotation.Transactional.class);
        assertTrue(transaction.readOnly());
        assertEquals(org.springframework.transaction.annotation.Isolation.REPEATABLE_READ,transaction.isolation());
    }
}
