package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AggregateMissingDeepAliasRepairTest {
    @Test void missingHistoricalBridgeUsesTheWholeExactResponsibilityAndReplayDoesNotWriteAgain() throws Exception {
        Fixture f=new Fixture(false,"1",false);
        f.service.repair(f.analysis,Set.of(f.leafB));
        JsonNode row=f.inserted.getFirst();
        assertThat(row.path("source_id").asText()).isEqualTo(f.leafB.toString());
        assertThat(row.path("parent_id").asText()).isEqualTo(f.parentB.toString());
        assertThat(row.path("target_id").asText()).isEqualTo(f.targetLeaf.toString());
        assertThat(row.path("edge_path").asText()).isEqualTo(f.middleEdge+"/"+f.leafEdge);
        // The first actual claim is one, but the immutable responsibility bridge is two.
        assertThat(row.path("qty").decimalValue()).isEqualByComparingTo("2");
        assertThat(row.path("source_capacity").decimalValue()).isEqualByComparingTo("2");
        f.service.repair(f.analysis,Set.of(f.leafB));
        assertThat(f.inserted).hasSize(1);
        assertThat(f.mutations).allMatch(sql->sql.startsWith("INSERT INTO preplan_aggregate_material_aliases"));
    }

    @Test void existingPrivateSupplyKeepsItsUntransferredResponsibility() {
        Fixture f=new Fixture(false,"10",false);
        f.service.repair(f.analysis,Set.of(f.leafB));
        assertThat(f.inserted.getFirst().path("qty").decimalValue()).isEqualByComparingTo("2");
        assertThat(f.inserted.getFirst().path("source_capacity").decimalValue()).isEqualByComparingTo("10");
    }

    @Test void intermediateOrdinaryManufacturingResponsibilityCannotBeCrossed() {
        Fixture f=new Fixture(true,"1",false);
        f.service.repair(f.analysis,Set.of(f.leafB));
        assertThat(f.inserted).isEmpty();
    }

    @Test void roundedTargetIsSharedOnceWithoutRetainingUnarrangedOldRounding() {
        Fixture f=new Fixture(false,"0",true);
        f.service.repair(f.analysis,Set.of(f.leafA,f.leafB,f.leafC));
        assertThat(f.inserted).hasSize(3);
        BigDecimal total=f.inserted.stream().map(row->row.path("qty").decimalValue()).reduce(BigDecimal.ZERO,BigDecimal::add);
        assertThat(total).isEqualByComparingTo("100");
        assertThat(f.inserted).allSatisfy(row->assertThat(row.path("source_capacity").decimalValue())
                .isEqualByComparingTo(row.path("qty").decimalValue()));
    }

    @Test void originalProductPriorityKeepsItsRecordedAllocationOrder() {
        Fixture f=new Fixture(false,"0",true);
        for(Object[] row:f.materials) {
            if(row[0].equals(id(10)))row[21]=2;
            if(row[0].equals(id(20)))row[21]=1;
            if(row[0].equals(id(30)))row[21]=3;
        }
        f.service.repair(f.analysis,Set.of(f.leafA,f.leafB,f.leafC));
        assertThat(f.inserted).hasSize(1);
        assertThat(f.inserted.getFirst().path("source_id").asText()).isEqualTo(f.leafB.toString());
        assertThat(f.inserted.getFirst().path("qty").decimalValue()).isEqualByComparingTo("100");
    }

    private static class Fixture {
        final UUID analysis=id(1),batch=id(2),action=id(3),anchor=id(4),parentB=id(20),leafA=id(12),leafB=id(22),leafC=id(32),
                targetLeaf=id(42),middleEdge=id(100),leafEdge=id(101),goods=id(200),unit=id(201);
        final ObjectMapper mapper=new ObjectMapper();
        final List<Object[]> batches=new ArrayList<>(),materials=new ArrayList<>(),aliases=new ArrayList<>();
        final List<JsonNode> inserted=new ArrayList<>();final List<String> mutations=new ArrayList<>();
        final AggregateMissingDeepAliasRepair service;
        Fixture(boolean frozen,String owned,boolean fixed) {
            for(int base:List.of(10,20,30)) {
                UUID item=id(base+1000),parent=id(base),middle=id(base+1),leaf=id(base+2);
                batches.add(new Object[]{batch,action,anchor,0L,new BigDecimal("3"),parent,BigDecimal.ONE});
                materials.add(row(parent,item,"p",null,"BOM_COMPONENT",id(99),"MAKE","0","1","PER_UNIT","1",false,1,"1","0","0","0"));
                materials.add(row(middle,item,"p/m","p","BOM_COMPONENT",middleEdge,"MAKE","0","1","PER_UNIT","1",frozen,2,"1","0","1","0"));
                materials.add(row(leaf,item,"p/m/d","p/m","BOM_COMPONENT",leafEdge,"BUY","0",fixed?"100":"2",fixed?"FIXED_BATCH":"PER_UNIT",fixed?"1000":"1",false,3,"0","0","0",base==20?owned:"0"));
                aliases.add(new Object[]{batch,middle,id(41),BigDecimal.ONE});
            }
            materials.add(row(id(41),anchor,"m",null,"BOM_COMPONENT",middleEdge,"MAKE","0","1","PER_UNIT","1",false,1,"3","3","3","0"));
            materials.add(row(targetLeaf,anchor,"m/d","m","BOM_COMPONENT",leafEdge,"BUY","0",fixed?"100":"2",fixed?"FIXED_BATCH":"PER_UNIT",fixed?"1000":"1",false,2,fixed?"100":"6","0","0","0"));
            EntityManager em=mock(EntityManager.class);
            when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
                String sql=invocation.getArgument(0);Query query=mock(Query.class);Map<String,Object> parameters=new HashMap<>();
                when(query.setParameter(anyString(),any())).thenAnswer(call->{parameters.put(call.getArgument(0),call.getArgument(1));return query;});
                if(sql.contains("SELECT batch.id,batch.action_id"))when(query.getResultList()).thenReturn(batches);
                else if(sql.contains("SELECT material.id,material.analysis_item_id"))when(query.getResultList()).thenReturn(materials);
                else if(sql.contains("SELECT alias.batch_id,alias.source_material_id"))when(query.getResultList()).thenAnswer(call->new ArrayList<>(aliases));
                else if(sql.stripLeading().startsWith("INSERT INTO preplan_aggregate_material_aliases"))when(query.executeUpdate()).thenAnswer(call->{
                    mutations.add(sql.stripLeading());
                    for(JsonNode row:mapper.readTree((String)parameters.get("rows"))) {
                        inserted.add(row);
                        aliases.add(new Object[]{UUID.fromString(row.path("batch_id").asText()),UUID.fromString(row.path("source_id").asText()),
                                UUID.fromString(row.path("target_id").asText()),row.path("qty").decimalValue()});
                    }
                    return inserted.size();
                });
                else throw new AssertionError("Unexpected mutation/read: "+sql);
                return query;
            });
            SecurityContextCurrentUser user=mock(SecurityContextCurrentUser.class);when(user.requireId()).thenReturn(id(900));
            PreplanStockEntitlementService entitlements=mock(PreplanStockEntitlementService.class);
            when(entitlements.delegateAggregateMakeEntitlements(any(),any())).thenReturn(BigDecimal.ZERO);
            service=new AggregateMissingDeepAliasRepair(em,mapper,user,entitlements);
        }
        private Object[] row(UUID id,UUID item,String node,String parent,String role,UUID edge,String route,String required,String qty,
                             String basis,String output,boolean frozen,int depth,String sourceCap,String targetCap,String historicCap,String owned) {
            return new Object[]{id,item,node,parent,role,edge,route,new BigDecimal(required),new BigDecimal(qty),basis,new BigDecimal(output),true,
                    goods,null,unit,new BigDecimal(sourceCap),new BigDecimal(targetCap),new BigDecimal(historicCap),new BigDecimal(owned),frozen,depth,0,null};
        }
    }
    private static UUID id(long value){return new UUID(0,value);}
}
