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

    @Test void weighedMaterialsAndExistingDrawLinesJoinTheHashOnlyWhenEntered() {
        Material line=material(GOODS_A,null,LEAF_A,"2");
        Request plain=new Request(KEY,List.of(DRAW_A),List.of(discovery(REQUEST_A,1,line)),null);
        Request zero=new Request(KEY,List.of(DRAW_A),List.of(new Discovery(REQUEST_A,1L,List.of(line),
                List.of(new IssueWeight(GOODS_A,null,LEAF_A,BigDecimal.ZERO,false)))),null,
                List.of(new com.uten.imp.features.stock.dto.StockDocIssueBatchRequest.ItemWeight(DRAW_B,null,null)));
        assertEquals(hash(plain),hash(zero),"没称(空或 0)的条目丢弃, 哈希与原口径一致");

        Request weighed=new Request(KEY,List.of(DRAW_A),List.of(new Discovery(REQUEST_A,1L,List.of(line),
                List.of(new IssueWeight(GOODS_A,null,LEAF_A,new BigDecimal("1.50"),null)))),null);
        Request sameScale=new Request(KEY,List.of(DRAW_A),List.of(new Discovery(REQUEST_A,1L,List.of(line),
                List.of(new IssueWeight(GOODS_A,null,LEAF_A,new BigDecimal("1.5000"),false)))),null);
        assertNotEquals(hash(plain),hash(weighed));
        assertEquals(hash(weighed),hash(sameScale));
        assertNotEquals(hash(weighed),hash(new Request(KEY,List.of(DRAW_A),List.of(new Discovery(REQUEST_A,1L,List.of(line),
                List.of(new IssueWeight(GOODS_A,null,LEAF_A,new BigDecimal("1.5"),true)))),null)));

        UUID item=id(30);
        Request itemWeighed=new Request(KEY,List.of(DRAW_A),List.of(discovery(REQUEST_A,1,line)),null,
                List.of(new com.uten.imp.features.stock.dto.StockDocIssueBatchRequest.ItemWeight(item,new BigDecimal("3"),null)));
        assertNotEquals(hash(plain),hash(itemWeighed));
        Request normalized=ProductionDrawDiscoveryBatchService.normalize(itemWeighed);
        assertEquals(new BigDecimal("3.0000"),normalized.weights().getFirst().weightKg());
        assertEquals(Boolean.FALSE,normalized.weights().getFirst().qtyFromWeight());
    }

    @Test void weightsMustNameAnActualMaterialOfTheRequestOnce() {
        Material line=material(GOODS_A,COLOR,LEAF_A,"2");
        rejected(new Request(KEY,List.of(),List.of(new Discovery(REQUEST_A,0L,List.of(line),
                List.of(new IssueWeight(GOODS_A,COLOR,LEAF_B,BigDecimal.ONE,null)))),null));
        rejected(new Request(KEY,List.of(),List.of(new Discovery(REQUEST_A,0L,List.of(line),
                List.of(new IssueWeight(GOODS_A,null,LEAF_A,BigDecimal.ONE,null)))),null));
        rejected(new Request(KEY,List.of(),List.of(new Discovery(REQUEST_A,0L,List.of(line),
                List.of(new IssueWeight(GOODS_A,COLOR,LEAF_A,BigDecimal.ONE,null),
                        new IssueWeight(GOODS_A,COLOR,LEAF_A,BigDecimal.TEN,null)))),null));
        rejected(new Request(KEY,List.of(),List.of(new Discovery(REQUEST_A,0L,List.of(line),
                List.of(new IssueWeight(GOODS_A,COLOR,LEAF_A,new BigDecimal("-1"),null)))),null));
        rejected(new Request(KEY,List.of(),List.of(new Discovery(REQUEST_A,0L,List.of(line),
                List.of(new IssueWeight(GOODS_A,COLOR,LEAF_A,new BigDecimal("0.00001"),null)))),null));
        UUID item=id(31);
        rejected(new Request(KEY,List.of(DRAW_A),List.of(),null,List.of(
                new com.uten.imp.features.stock.dto.StockDocIssueBatchRequest.ItemWeight(item,BigDecimal.ONE,null),
                new com.uten.imp.features.stock.dto.StockDocIssueBatchRequest.ItemWeight(item,BigDecimal.TEN,null))));

        Request accepted=ProductionDrawDiscoveryBatchService.normalize(new Request(KEY,List.of(),List.of(
                new Discovery(REQUEST_A,0L,List.of(line),List.of(new IssueWeight(GOODS_A,COLOR,LEAF_A,new BigDecimal("0.25"),null)))),null));
        IssueWeight weight=accepted.discoveries().getFirst().weights().getFirst();
        assertEquals(new BigDecimal("0.2500"),weight.weightKg());
        assertEquals(Boolean.FALSE,weight.qtyFromWeight());
    }

    /**
     * 客户端 /issue-discovery-batch 请求体原样反序列化(未知字段即失败; 线上 Jackson 静默丢弃未知字段):
     * 顶层 weights 是已有领料明细的重量, discoveries[].weights 是待确认材料的重量, 两者都进哈希;
     * 不带这两个键 = 都没称, 哈希与原口径一致(lib/features/warehouse/repositories/production_draw_task_repository.dart)。
     */
    @Test void clientJsonBindsTopLevelAndDiscoveryWeightsAndMissingKeysMeanUnweighed() throws Exception {
        var strict=com.fasterxml.jackson.databind.json.JsonMapper.builder().findAndAddModules()
                .enable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES).build();
        UUID item=id(32);
        String discovery="{\"requestId\":\"%s\",\"expectedVersion\":1,"
                +"\"items\":[{\"goodsId\":\"%s\",\"colorId\":null,\"unitId\":\"%s\",\"warehouseId\":\"%s\",\"qty\":\"2\"}]%s}";
        String materialWeights=(",\"weights\":[{\"goodsId\":\"%s\",\"colorId\":null,\"warehouseId\":\"%s\","
                +"\"weightKg\":0.85,\"qtyFromWeight\":true}]").formatted(GOODS_A,LEAF_A);
        Request weighed=strict.readValue("""
                {"idempotencyKey":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","docIds":["%s"],
                 "discoveries":[%s],
                 "weights":[{"itemId":"%s","weightKg":1.25,"qtyFromWeight":false}],"reason":"交接"}
                """.formatted(DRAW_A,discovery.formatted(REQUEST_A,GOODS_A,UNIT,LEAF_A,materialWeights),item),
                Request.class);
        Request normalized=ProductionDrawDiscoveryBatchService.normalize(weighed);
        assertEquals(new BigDecimal("1.2500"),normalized.weights().getFirst().weightKg());
        assertEquals(item,normalized.weights().getFirst().itemId());
        IssueWeight material=normalized.discoveries().getFirst().weights().getFirst();
        assertEquals(new BigDecimal("0.8500"),material.weightKg());
        assertEquals(Boolean.TRUE,material.qtyFromWeight());

        Request plain=strict.readValue("""
                {"idempotencyKey":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","docIds":["%s"],"discoveries":[%s],"reason":"交接"}
                """.formatted(DRAW_A,discovery.formatted(REQUEST_A,GOODS_A,UNIT,LEAF_A,"")),Request.class);
        assertNull(plain.weights());
        assertNull(plain.discoveries().getFirst().weights());
        Material line=material(GOODS_A,null,LEAF_A,"2");
        assertEquals(hash(new Request("1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",List.of(DRAW_A),
                List.of(discovery(REQUEST_A,1,line)),"交接")),hash(plain));
        assertNotEquals(hash(plain),hash(weighed));
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
