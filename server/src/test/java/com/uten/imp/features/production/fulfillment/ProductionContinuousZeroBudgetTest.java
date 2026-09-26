package com.uten.imp.features.production.fulfillment;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class ProductionContinuousZeroBudgetTest {
    @Test void futureCommitmentWithoutPhysicalStockDoesNotReadReceiptLineage() throws Exception {
        var result=run("0","0","0","80",false);
        assertTrue(result.increments().isEmpty());
        assertEquals(0,result.receiptQueries());
    }

    @Test void qualifiedOwnedStockAboveSafetyStillChecksItsSources() throws Exception {
        var result=run("20","0","100","80",false);
        assertEquals(1,result.increments().size());
        assertEquals(0,new BigDecimal("20").compareTo(ReflectionTestUtils.invokeMethod(result.increments().getFirst(),"requiredQty")));
        assertTrue(result.receiptQueries()>0);
    }

    @Test void qualifiedOwnedStockWithoutFutureSupplyNeedsNoEmptyReceiptScans() throws Exception {
        var result=run("20","0","100","0",false);
        assertEquals(1,result.increments().size());
        assertEquals(0,result.receiptQueries());
    }

    @Test void privateReturnedCustodyIsNotMistakenForAnEmptyPublicPool() throws Exception {
        var result=run("0","20","100","0",true);
        assertEquals(1,result.increments().size());
        assertEquals(0,new BigDecimal("20").compareTo(ReflectionTestUtils.invokeMethod(result.increments().getFirst(),"requiredQty")));
        assertTrue(result.receiptQueries()>0);
    }

    private record Result(List<?> increments,int receiptQueries) {}
    private Result run(String qualified,String custody,String safety,String future,boolean reclaim) throws Exception {
        EntityManager em=mock(EntityManager.class);
        ProductionExecutionReadinessService service=mock(ProductionExecutionReadinessService.class,CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service,"em",em);
        UUID demand=UUID.randomUUID(),goods=UUID.randomUUID(),unit=UUID.randomUUID(),warehouse=UUID.randomUUID();
        var type=Class.forName(ProductionExecutionReadinessService.class.getName()+"$DemandRow");
        var constructor=type.getDeclaredConstructor(UUID.class,UUID.class,UUID.class,UUID.class,BigDecimal.class,boolean.class);
        constructor.setAccessible(true);
        Object row=constructor.newInstance(demand,goods,null,unit,new BigDecimal("100"),false);
        List<String> statements=new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);statements.add(sql);
            Query query=mock(Query.class,RETURNS_SELF);
            if(sql.contains(" AS receipt_demand_id")) {
                when(query.getResultList()).thenReturn(new BigDecimal(future).signum()>0||new BigDecimal(custody).signum()>0?List.of(demand):List.of());
            } else if(sql.contains(" AS public_allowed")) {
                BigDecimal q=new BigDecimal(qualified),c=new BigDecimal(custody),physical=q.add(c);
                when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{demand,warehouse,physical,physical,q,q,
                        new BigDecimal(safety),true,true,"G","Goods","Warehouse",false,null,c}));
            } else if(sql.contains("SUM(r.qty-r.released_qty)")) {
                when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{demand,BigDecimal.ZERO,new BigDecimal(future)}));
            } else when(query.getResultList()).thenReturn(List.of());
            return query;
        });
        List<?> increments=ReflectionTestUtils.invokeMethod(service,"continuousIncrement",warehouse,List.of(row),UUID.randomUUID(),UUID.randomUUID(),
                null,ProductionExecutionReadinessService.ReceiptKind.PLAN_GROWTH,reclaim);
        return new Result(increments,(int)statements.stream().filter(sql->sql.contains("JOIN purchase_receipt_items")
                ||sql.contains("JOIN subcontract_receipt_items")||sql.contains("JOIN stock_document_items receipt_item")).count());
    }
}
