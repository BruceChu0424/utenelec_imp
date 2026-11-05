package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class DocumentQuantitySavePlanTest {
    private static final UUID PARENT=UUID.randomUUID(),ONE=UUID.randomUUID(),TWO=UUID.randomUUID(),GOODS=UUID.randomUUID(),UNIT=UUID.randomUUID(),SOURCE=UUID.randomUUID();
    private static Map<String,Object> operands(String qty){
        var values=new LinkedHashMap<String,Object>();values.put("goods_id",GOODS);values.put("color_id",null);values.put("unit_id",UNIT);
        values.put("unit_rate",new BigDecimal("1.00005"));values.put("qty",new BigDecimal(qty));values.put("quantity_semantics","LEGACY_RECORDED");
        values.put("gift_qty",BigDecimal.ZERO);values.put("order_item_id",SOURCE);values.put("replacement_intent",null);values.put("gift_replacement_intent",null);return values;
    }
    private static DocumentQuantitySavePlan.Intent input(int position,UUID identity,String qty){return new DocumentQuantitySavePlan.Intent(position,identity,operands(qty));}
    private static String original(UUID id,int position,String qty,String base,int version){return "{\"id\":\""+id+"\",\"line_no\":"+position+",\"goods_id\":\""+GOODS+"\",\"color_id\":null,\"unit_id\":\""+UNIT+"\",\"unit_rate\":1.00005,\"qty\":"+qty+",\"quantity_semantics\":\"LEGACY_RECORDED\",\"gift_qty\":0,\"order_item_id\":\""+SOURCE+"\",\"replacement_intent\":null,\"gift_replacement_intent\":null,\"charged_base_qty\":"+base+",\"gift_base_qty\":0,\"quantity_adoption_version\":"+version+",\"quantity_precision_policy\":"+(version==1?"null":"{\"version\":1,\"choices\":{}}")+"}";}
    private static EntityManager database(String...rows){var em=mock(EntityManager.class);var query=mock(Query.class);when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);when(query.getResultList()).thenReturn(List.of(rows));return em;}
    @Test @SuppressWarnings("try") void anUnrelatedChoiceCannotReadoptAnOriginalRecordedBase()throws Exception {
        var em=database(original(ONE,1,"1","1.0001",1));
        try(var scope=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(0,"HALF_UP")))){
            var saved=DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(input(1,null,"1"))).saved(1);
            assertThat(saved.id()).isEqualTo(ONE);assertThat(saved.procurement("LEGACY_RECORDED",BigDecimal.ONE,BigDecimal.ZERO,new BigDecimal("1.00005")).chargedBase()).isEqualByComparingTo("1.0001");
            assertThat(BusinessPrecisionContext.usedChoices()).isEmpty();
        }
    }
    @Test void anImplicitGiftIntentKeepsItsOriginalStoredRepresentation(){
        String json=original(ONE,1,"1","1.0001",1).replace("\"replacement_intent\":null","\"replacement_intent\":\"ORIGINAL\"");
        var em=database(json);var fields=operands("1");fields.put("replacement_intent","ORIGINAL");fields.put("gift_replacement_intent","ORIGINAL");
        var saved=DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(new DocumentQuantitySavePlan.Intent(1,ONE,fields))).saved(1);
        assertThat(saved.id()).isEqualTo(ONE);assertThat(saved.text("gift_replacement_intent")).isNull();
        assertThatThrownBy(()->DocumentQuantitySavePlan.identity(ONE,TWO)).isInstanceOf(ApiException.class);
    }
    @Test void differentOriginalAdoptionsCannotBeGuessedFromOtherwiseIdenticalRows(){
        var em=database(original(ONE,1,"1","1.0001",1),original(TWO,2,"1","1.00005",2));
        assertThatThrownBy(()->DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(input(1,null,"1")))).isInstanceOf(ApiException.class);
        var saved=DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(input(1,TWO,"1"))).saved(1);
        assertThat(saved.id()).isEqualTo(TWO);assertThat(saved.decimal("charged_base_qty")).isEqualByComparingTo("1.00005");
    }
    @Test void aNewDuplicateBeforeItsOriginalCannotConsumeThatOriginalIdentity(){
        var em=database(original(ONE,1,"1","1.0001",1));
        var plan=DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(input(1,null,"1"),input(2,ONE,"1")));
        assertThat(plan.saved(1)).isNull();assertThat(plan.saved(2).id()).isEqualTo(ONE);
    }
    @Test void missingHistoricalBasisRejectsBeforeNormalizingButKnownDefaultOneAndNewRowsRemainValid(){
        String missing=original(ONE,1,"1","1.0001",1).replace("\"unit_id\":\""+UNIT+"\"","\"unit_id\":null").replace("\"unit_rate\":1.00005","\"unit_rate\":null");
        var old=database(missing);var raw=operands("1");raw.put("unit_id",null);raw.put("unit_rate",null);
        var normalized=new java.util.concurrent.atomic.AtomicBoolean();
        assertThatThrownBy(()->DocumentQuantitySavePlan.prepare(old,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(new DocumentQuantitySavePlan.Intent(1,ONE,raw)),input->{normalized.set(true);return input.units(UNIT,BigDecimal.ONE);})).isInstanceOf(ApiException.class).hasMessageContaining("原明细单位/换算率缺少依据");
        assertThat(normalized.get()).isFalse();
        var fresh=new LinkedHashMap<>(raw);fresh.put("qty",new BigDecimal("2"));
        assertThat(DocumentQuantitySavePlan.prepare(old,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(new DocumentQuantitySavePlan.Intent(1,null,fresh)),input->input.units(UNIT,BigDecimal.ONE)).saved(1)).isNull();
        var known=database(original(ONE,1,"1","1",1).replace("\"unit_rate\":1.00005","\"unit_rate\":1"));
        var omitted=operands("1");omitted.put("unit_rate",null);
        assertThat(DocumentQuantitySavePlan.prepare(known,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(new DocumentQuantitySavePlan.Intent(1,ONE,omitted)),input->input.units(UNIT,BigDecimal.ONE)).saved(1).id()).isEqualTo(ONE);
    }
    @Test void identityIsOnlyALocatorAndCannotBorrowOrDuplicateAnOriginalRow(){
        var em=database(original(ONE,1,"1","1.0001",1));
        assertThatThrownBy(()->DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(input(1,TWO,"1")))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(input(1,ONE,"1"),input(2,ONE,"1")))).isInstanceOf(ApiException.class);
        assertThat(DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(input(1,ONE,"2"))).saved(1)).isNull();
    }
    @Test void explicitReorderingRemainsOneToOneAndKeepsEachRecordedDecision(){
        var em=database(original(ONE,1,"1","1.0001",1),original(TWO,2,"2","2.0001",2));
        var plan=DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(input(1,TWO,"2"),input(2,ONE,"1")));
        assertThat(plan.saved(1).id()).isEqualTo(TWO);assertThat(plan.saved(2).id()).isEqualTo(ONE);
        plan.deleteReplaced(em);verify(em).createNativeQuery(contains("WHERE receipt_id=:parent AND id NOT IN(:kept)"));
    }
    @Test void noCallerCanOmitAnOwningSourceOperand(){
        var em=database(original(ONE,1,"1","1.0001",1));var missing=operands("1");missing.remove("order_item_id");
        assertThatThrownBy(()->DocumentQuantitySavePlan.prepare(em,DocumentQuantitySavePlan.Family.PURCHASE_RECEIPT,PARENT,List.of(new DocumentQuantitySavePlan.Intent(1,ONE,missing)))).isInstanceOf(IllegalArgumentException.class);
    }
}
