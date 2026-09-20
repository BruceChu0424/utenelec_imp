package com.uten.imp.businesschain;

import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService;
import com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest;
import com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest;
import static org.junit.jupiter.api.Assertions.*;

@org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopMaterialReturnSourceConservationEndToEndTest extends WorkshopMaterialReturnAuditSupport {
    @ParameterizedTest
    @ValueSource(strings={"CONSUMED","APPROVED_LOSS","LEGAL_WIP"})
    void consumedSourceMustNotBecomeAnotherReturnAfterOutOfOrderCounters(String settlementType){
        Object c=read(this,"create","mix-"+settlementType,false);
        UUID[] target=new UUID[]{read(c,"plan"),read(c,"segment"),read(this,"parentDemand",c)};
        UUID worker=read(c,"workerUser"),warehouse=read(c,"leaf"),goods=read(c,"child");
        FullChainEndToEndTest.World world=read(c,"world");
        read(this,"transferTo",c,target[2],"5");read(this,"transferTo",c,target[2],"5");
        read(this,"confirmRoute",target[0],target[1],"CONTINUOUS");
        fixture.loginAs(worker);segments.start(target[0],target[1],new SegmentTransitionRequest(versionOf(target[1]),"audit-start"));
        List<UUID> allocations=db.queryForList("SELECT source.id FROM production_workshop_direct_source_allocations source JOIN stock_reservations held ON held.id=source.stock_reservation_id WHERE held.demand_id=? ORDER BY allocation_no",UUID.class,target[2]);
        assertEquals(2,allocations.size());UUID a=allocations.get(0),b=allocations.get(1);
        UUID issue=db.queryForObject("SELECT id FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",UUID.class,target[2]);
        UUID first=returned(world,worker,target,issue,warehouse,"3","a");
        UUID second=returned(world,worker,target,issue,warehouse,"5","b");
        fixture.loginAs(world.superAdminUserId());stock.reverse(first);
        assertQty("3",net(a));assertQty("2",net(b));
        var settlement=new ProductionMaterialSettlementRequest();settlement.setExecutionSegmentId(target[1]);settlement.setIdempotencyKey("audit-consume");settlement.setReason("Only A3 plus B2 exist in WIP at this point");
        var line=new ProductionMaterialSettlementRequest.Line();line.setDemandId(target[2]);line.setSettlementType(settlementType);line.setQtyBase(new BigDecimal("5"));settlement.setLines(List.of(line));
        beans.getBean(ProductionMaterialSettlementService.class).post(target[0],settlement,world.superAdminUserId());
        UUID settlementId=db.queryForObject("SELECT id FROM production_material_settlement_postings WHERE demand_id=? AND source_posting_id IS NULL",UUID.class,target[2]);
        String consumed=db.queryForObject("SELECT to_jsonb(posting)::text FROM production_material_settlement_postings posting WHERE id=?",String.class,settlementId);
        String sourceSlices=db.queryForObject("SELECT jsonb_agg(to_jsonb(source) ORDER BY event_no)::text FROM production_workshop_direct_source_events source WHERE settlement_posting_id=?",String.class,settlementId);
        assertQty("3",sourceSettlement(settlementId,a));assertQty("2",sourceSettlement(settlementId,b));
        stock.reverse(second);assertQty("5",net(a));assertQty("5",net(b));
        read(this,"poolValue",warehouse,goods,"0","0");
        UUID third=returned(world,worker,target,issue,warehouse,"5","c");
        assertEquals(consumed,db.queryForObject("SELECT to_jsonb(posting)::text FROM production_material_settlement_postings posting WHERE id=?",String.class,settlementId));
        assertEquals(sourceSlices,db.queryForObject("SELECT jsonb_agg(to_jsonb(source) ORDER BY event_no)::text FROM production_workshop_direct_source_events source WHERE settlement_posting_id=?",String.class,settlementId));
        System.out.println("AUDIT_"+settlementType+"5_AT_A3_B2 final_A="+net(a)+" final_B="+net(b)+" third="+third);
        assertQty("3",net(a));assertQty("2",net(b));
        reverseSettlement(world,target,settlementId,settlementType,"2","partial");
        assertQty("2",sourceSettlementCounter(settlementId,a));assertQty("0",sourceSettlementCounter(settlementId,b));
        returned(world,worker,target,issue,warehouse,"2","after-partial");
        assertQty("1",net(a));assertQty("2",net(b));
        reverseSettlement(world,target,settlementId,settlementType,"3","remaining");
        assertQty("3",sourceSettlementCounter(settlementId,a));assertQty("2",sourceSettlementCounter(settlementId,b));
        returned(world,worker,target,issue,warehouse,"3","after-remaining");
        assertQty("0",net(a));assertQty("0",net(b));
    }
    private UUID returned(FullChainEndToEndTest.World world,UUID worker,UUID[] target,UUID issue,UUID receiving,String qty,String suffix){
        fixture.loginAs(worker);
        var request=beans.getBean(ProductionMaterialReturnRequestService.class).submit(target[0],new ProductionMaterialReturnRequest.Submit(target[1],"audit-return-"+suffix,"Audit exact source",List.of(new ProductionMaterialReturnRequest.Item(issue,new BigDecimal(qty))))).getFirst();
        fixture.loginAs(world.superAdminUserId());stock.confirmProductionMaterialReturn(request.documentId(),new ProductionMaterialReturnConfirmRequest(receiving,"audit-receive-"+suffix));return request.documentId();
    }
    private BigDecimal net(UUID id){return db.queryForObject("SELECT net_issued_qty FROM v_workshop_direct_source_allocations WHERE id=?",BigDecimal.class,id);}
    private BigDecimal sourceSettlement(UUID posting,UUID allocation){return db.queryForObject("SELECT COALESCE(SUM(qty_base),0) FROM production_workshop_direct_source_events WHERE settlement_posting_id=? AND source_allocation_id=?",BigDecimal.class,posting,allocation);}
    private BigDecimal sourceSettlementCounter(UUID posting,UUID allocation){return db.queryForObject("SELECT COALESCE(SUM(counter.qty_base),0) FROM production_workshop_direct_source_events original JOIN production_workshop_direct_source_events counter ON counter.counter_event_id=original.id WHERE original.settlement_posting_id=? AND original.source_allocation_id=?",BigDecimal.class,posting,allocation);}
    private void reverseSettlement(FullChainEndToEndTest.World world,UUID[] target,UUID posting,String type,String qty,String suffix){
        fixture.loginAs(world.superAdminUserId());
        var request=new ProductionMaterialSettlementRequest();request.setExecutionSegmentId(target[1]);request.setIdempotencyKey("audit-unsettle-"+suffix);request.setReason("Reverse only the immutable original source slices");
        var line=new ProductionMaterialSettlementRequest.Line();line.setDemandId(target[2]);line.setSettlementType(type);line.setQtyBase(new BigDecimal(qty));line.setSourcePostingId(posting);request.setLines(List.of(line));
        beans.getBean(ProductionMaterialSettlementService.class).reverse(target[0],request,world.superAdminUserId());
    }
    private void assertQty(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual));}
}
