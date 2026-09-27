package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.stream.IntStream;

import static com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts.*;
import static com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Material;
import static org.junit.jupiter.api.Assertions.*;

class ProductionDrawDiscoveryBatchContractTest {
    private static final UUID DRAW_A=id(1), DRAW_B=id(2), REQUEST_A=id(3), REQUEST_B=id(4);
    private static final UUID GOODS_A=id(10), GOODS_B=id(11), COLOR=id(12), UNIT=id(13);
    private static final UUID LEAF_A=id(20), LEAF_B=id(21);
    private static final String KEY="discovery-batch-contract";

    @Test void reorderingTasksAndMaterialRowsOrChangingDecimalScaleKeepsTheSameIntent() {
        Request first=new Request(KEY,List.of(DRAW_B,DRAW_A),List.of(
                discovery(REQUEST_B,8,material(GOODS_B,COLOR,LEAF_A,"3.0000")),
                discovery(REQUEST_A,7,material(GOODS_A,null,LEAF_B,"2.5000"),
                        material(GOODS_A,null,LEAF_A,"1.0000"))),"  交接  ");
        Request retry=new Request(KEY,List.of(DRAW_A,DRAW_B),List.of(
                discovery(REQUEST_A,7,material(GOODS_A,null,LEAF_A,"1"),
                        material(GOODS_A,null,LEAF_B,"2.5")),
                discovery(REQUEST_B,8,material(GOODS_B,COLOR,LEAF_A,"3"))),"交接");

        assertEquals(hash(first),hash(retry));
        Request normalized=ProductionDrawDiscoveryBatchService.normalize(first);
        assertEquals(List.of(DRAW_A,DRAW_B),normalized.docIds());
        assertEquals(List.of(REQUEST_A,REQUEST_B),normalized.discoveries().stream().map(Discovery::requestId).toList());
        assertEquals("交接",normalized.reason());
        assertEquals(hash(new Request(KEY,List.of(DRAW_A),null,null)),
                hash(new Request(KEY,List.of(DRAW_A),List.of(),"   ")));
    }

    @Test void splitWarehousesRetainTwoPhysicalSourcesAndTheirOwnQuantities() {
        Request normalized=ProductionDrawDiscoveryBatchService.normalize(new Request(KEY,List.of(),List.of(
                discovery(REQUEST_A,0,material(GOODS_A,COLOR,LEAF_B,"7.5"),
                        material(GOODS_A,COLOR,LEAF_A,"2.5"))),null));

        List<Material> lines=normalized.discoveries().getFirst().items();
        assertEquals(2,lines.size());
        assertEquals(List.of(LEAF_A,LEAF_B),lines.stream().map(Material::warehouseId).toList());
        assertEquals(0,new BigDecimal("2.5").compareTo(lines.getFirst().qty()));
        assertEquals(0,new BigDecimal("7.5").compareTo(lines.getLast().qty()));
        assertTrue(lines.stream().allMatch(line->line.goodsId().equals(GOODS_A)&&line.colorId().equals(COLOR)));
    }

    @Test void oneWarehouseCannotRepeatTheSameMaterialButDifferentColorsRemainDistinct() {
        Material line=material(GOODS_A,null,LEAF_A,"2");
        rejected(new Request(KEY,List.of(),List.of(discovery(REQUEST_A,0,line,line)),null));

        Request accepted=ProductionDrawDiscoveryBatchService.normalize(new Request(KEY,List.of(),List.of(
                discovery(REQUEST_A,0,line,material(GOODS_A,COLOR,LEAF_A,"3"))),null));
        assertEquals(2,accepted.discoveries().getFirst().items().size());
    }

    @Test void everyReviewedIdentityQuantitySourceVersionAndRemarkBelongsToTheBatchHash() {
        Request base=request(DRAW_A,REQUEST_A,7,material(GOODS_A,null,LEAF_A,"2.5"),"交接");
        String original=hash(base);
        List<Request> changed=List.of(
                request(DRAW_B,REQUEST_A,7,material(GOODS_A,null,LEAF_A,"2.5"),"交接"),
                new Request(KEY,List.of(DRAW_A,DRAW_B),base.discoveries(),"交接"),
                request(DRAW_A,REQUEST_B,7,material(GOODS_A,null,LEAF_A,"2.5"),"交接"),
                request(DRAW_A,REQUEST_A,8,material(GOODS_A,null,LEAF_A,"2.5"),"交接"),
                request(DRAW_A,REQUEST_A,7,material(GOODS_B,null,LEAF_A,"2.5"),"交接"),
                request(DRAW_A,REQUEST_A,7,material(GOODS_A,COLOR,LEAF_A,"2.5"),"交接"),
                request(DRAW_A,REQUEST_A,7,new Material(GOODS_A,null,id(14),LEAF_A,new BigDecimal("2.5")),"交接"),
                request(DRAW_A,REQUEST_A,7,material(GOODS_A,null,LEAF_B,"2.5"),"交接"),
                request(DRAW_A,REQUEST_A,7,material(GOODS_A,null,LEAF_A,"2.6"),"交接"),
                request(DRAW_A,REQUEST_A,7,material(GOODS_A,null,LEAF_A,"2.5"),"另一交接"));
        for(Request candidate:changed)assertNotEquals(original,hash(candidate),candidate.toString());
    }

    @Test void combinedTaskLimitCountsExistingDrawsAndDiscoveryRequests() {
        List<UUID> fortyNine=IntStream.range(100,149).mapToObj(ProductionDrawDiscoveryBatchContractTest::id).toList();
        Discovery discovery=discovery(REQUEST_A,0,material(GOODS_A,null,LEAF_A,"1"));
        assertDoesNotThrow(()->ProductionDrawDiscoveryBatchService.normalize(new Request(KEY,fortyNine,List.of(discovery),null)));
        List<UUID> fifty=new ArrayList<>(fortyNine);fifty.add(id(149));
        rejected(new Request(KEY,fifty,List.of(discovery),null));
        assertDoesNotThrow(()->ProductionDrawDiscoveryBatchService.normalize(new Request(KEY,fifty,List.of(),null)));
        rejected(new Request(KEY,List.of(),List.of(),null));
        rejected(null);
    }

    @Test void missingOrDuplicatedTaskIdentityAndInvalidCommandMetadataAreRejected() {
        Material line=material(GOODS_A,null,LEAF_A,"1");
        Discovery discovery=discovery(REQUEST_A,0,line);
        rejected(new Request(KEY,List.of(DRAW_A,DRAW_A),List.of(),null));
        rejected(new Request(KEY,Arrays.asList(DRAW_A,null),List.of(),null));
        rejected(new Request(KEY,List.of(),List.of(discovery,discovery),null));
        rejected(new Request(KEY,List.of(),Arrays.asList((Discovery)null),null));
        rejected(new Request(KEY,List.of(),List.of(new Discovery(null,0L,List.of(line))),null));
        rejected(new Request(KEY,List.of(),List.of(new Discovery(REQUEST_A,null,List.of(line))),null));
        rejected(new Request(KEY,List.of(),List.of(discovery(REQUEST_A,-1,line)),null));
        rejected(new Request("short",List.of(DRAW_A),List.of(),null));
        rejected(new Request("invalid/key",List.of(DRAW_A),List.of(),null));
        rejected(new Request(KEY,List.of(DRAW_A),List.of(),"字".repeat(201)));
    }

    @Test void configurationRequiresConcreteMaterialUnitWarehouseAndPositiveBoundedQuantity() {
        List<Material> invalid=Arrays.asList(null,
                new Material(null,null,UNIT,LEAF_A,BigDecimal.ONE),
                new Material(GOODS_A,null,null,LEAF_A,BigDecimal.ONE),
                new Material(GOODS_A,null,UNIT,null,BigDecimal.ONE),
                new Material(GOODS_A,null,UNIT,LEAF_A,null),
                material(GOODS_A,null,LEAF_A,"0"),
                material(GOODS_A,null,LEAF_A,"-1"),
                material(GOODS_A,null,LEAF_A,"0.00001"),
                material(GOODS_A,null,LEAF_A,"100000000000000"));
        for(Material line:invalid)rejected(new Request(KEY,List.of(),List.of(
                new Discovery(REQUEST_A,0L,Arrays.asList(line))),null));
        rejected(new Request(KEY,List.of(),List.of(new Discovery(REQUEST_A,0L,List.of())),null));
        rejected(new Request(KEY,List.of(),List.of(new Discovery(REQUEST_A,0L,null)),null));
    }

    private static Request request(UUID draw,UUID requestId,long version,Material material,String reason) {
        return new Request(KEY,List.of(draw),List.of(discovery(requestId,version,material)),reason);
    }
    private static Discovery discovery(UUID requestId,long version,Material... materials) {
        return new Discovery(requestId,version,Arrays.asList(materials));
    }
    private static Material material(UUID goods,UUID color,UUID warehouse,String quantity) {
        return new Material(goods,color,UNIT,warehouse,new BigDecimal(quantity));
    }
    private static String hash(Request request) {
        return ProductionDrawDiscoveryBatchService.requestHash(ProductionDrawDiscoveryBatchService.normalize(request));
    }
    private static void rejected(Request request) {
        ApiException failure=assertThrows(ApiException.class,()->ProductionDrawDiscoveryBatchService.normalize(request));
        assertEquals(ErrorCode.VALIDATION_FAILED,failure.getCode());
    }
    private static UUID id(int value) {return new UUID(0,value);}
}
