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

    @Test void privateReturnedCustodyIsNotReclaimedWithoutExplicitIntent() throws Exception {
        var result=run("0","20","100","0",false);
        assertTrue(result.increments().isEmpty());
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
        List<Query> anomalyQueries=new ArrayList<>();
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
            } else if (sql.stripLeading().startsWith("SELECT DISTINCT warehouse.name")) {
                assertTrue(sql.contains("JOIN production_workshop_direct_legacy_anomalies anomaly"));
                assertTrue(sql.contains("anomaly.goods_id=demand.goods_id AND anomaly.color_id IS NOT DISTINCT FROM demand.color_id"));
                assertTrue(sql.contains("direct.to_demand_id IN(demand.id,demand.split_root_demand_id) AND direct.reversal_id IS NULL"));
                assertTrue(sql.contains("WHERE demand.id IN (:demands)") && sql.contains("LIMIT 3"));
                // These budget fixtures have no legacy workshop anomaly. This
                // independent safety query is not a receipt-lineage scan.
                anomalyQueries.add(query);
                when(query.getResultList()).thenReturn(List.of());
            } else if (receiptLineage(sql)) {
                assertNativeReceiptLineage(sql);
                when(query.getResultList()).thenReturn(List.of());
            } else throw new AssertionError("Unexpected continuous-increment SQL: " + sql);
            return query;
        });
        Object snapshot=ReflectionTestUtils.invokeMethod(service,"continuousIncrement",warehouse,List.of(row),UUID.randomUUID(),UUID.randomUUID(),
                reclaim);
        List<?> increments=ReflectionTestUtils.invokeMethod(snapshot,"demands");
        assertEquals(1,anomalyQueries.size());
        verify(anomalyQueries.getFirst()).setParameter("demands",List.of(demand));
        return new Result(increments,(int)statements.stream().filter(ProductionContinuousZeroBudgetTest::receiptLineage).count());
    }

    private static boolean receiptLineage(String sql) {
        return sql.replaceAll("\\s+", "").startsWith("SELECTreceipt.id,receipt_item.id,peg.id,");
    }

    private static void assertNativeReceiptLineage(String sql) {
        String compact = sql.replaceAll("\\s+", "");
        String itemTable;
        String headerTable;
        if (compact.contains("'PURCHASE'::text")) {
            itemTable = "purchase_receipt_items"; headerTable = "purchase_receipts";
            assertTrue(compact.contains("'PURCHASE_ORDER_ITEM'"));
        } else if (compact.contains("'SUBCONTRACT'::text")) {
            itemTable = "subcontract_receipt_items"; headerTable = "subcontract_receipts";
            assertTrue(compact.contains("'SUBCONTRACT_ORDER_ITEM'"));
        } else {
            assertTrue(compact.contains("'MAKE'::text"));
            itemTable = "stock_document_items"; headerTable = "stock_documents";
            assertTrue(compact.contains("'PRODUCTION_PLAN_ITEM'"));
        }
        for (String table : List.of(itemTable, headerTable)) {
            assertTrue(compact.contains("NOTfn_imported_business_document('" + table + "',archive_origin.id)"),
                    "receipt lineage must exclude imported " + table);
        }
        assertTrue(compact.contains("WHEREpeg.demand_id=:demandId")
                || (compact.contains("FROMstock_reservationscustody")
                    && compact.contains("custody.owner_type='WORKSHOP_CUSTODY'")
                    && compact.contains("custody.owner_id=:demand")), "receipt sources must belong to the exact demand");
    }
}
