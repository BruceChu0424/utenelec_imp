package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsNativeBudgetContractTest {
    private static final String FULL="1234567890123456789012345678901234567890.123456789012345678901234";
    @Test void actualWriteKeysAndExplicitNullHavePresenceWithoutInventingPriceText()throws Exception {
        var json=new ObjectMapper();
        var absent=json.readValue("{}",GoodsSaveRequest.class);
        assertThat(absent.hasPrice()).isFalse();
        assertThat(absent.hasDiscount()).isFalse();
        assertThat(absent.hasCostField("sourceE")).isFalse();
        var original=json.readValue("{\"price\":\""+FULL+"\",\"discount\":\"0.123456789012345678901234\",\"sourceE\":\""+FULL+"\",\"cTotal\":null}",GoodsSaveRequest.class);
        assertThat(original.hasPrice()).isTrue();
        assertThat(original.getPrice().toPlainString()).isEqualTo(FULL);
        assertThat(original.hasCostField("sourceE")).isTrue();
        assertThat(original.hasCostField("cTotal")).isTrue();
        assertThat(original.getCTotal()).isNull();
        assertThat(original.hasCostField("gTotal")).isFalse();
        assertThatCode(()->GoodsCostValuePolicy.validateRequest(original)).doesNotThrowAnyException();
    }
    @Test void everyBudgetFieldUsesTheSameNativeBoundaryAndKeepsRateBounds()throws Exception {
        var validator=Validation.buildDefaultValidatorFactory().getValidator();
        for(String field:java.util.List.of("sourceE","machiningE","incidentalE","lacquerE","platingE","casingE","polishE","total","workE","lostE","rentE","makeE","cTotal","gTotal")){
            var request=new ObjectMapper().convertValue(Map.of("categoryId",java.util.UUID.randomUUID(),"name","匿名货品",field,FULL),GoodsSaveRequest.class);
            assertThat(validator.validate(request)).as(field).isEmpty();
            assertThatCode(()->GoodsCostValuePolicy.validateRequest(request)).doesNotThrowAnyException();
        }
        var rate=new ObjectMapper().convertValue(Map.of("categoryId",java.util.UUID.randomUUID(),"name","匿名货品","workRate","99.123456789012345678901234"),GoodsSaveRequest.class);
        assertThat(validator.validate(rate)).isEmpty();
        rate.setWorkRate(new BigDecimal("100.000000000000000000000001"));
        assertThat(validator.validate(rate)).isNotEmpty();
        assertThatThrownBy(()->GoodsCostValuePolicy.validateRequest(rate)).hasMessageContaining("人工比率");
        rate.setWorkRate(new BigDecimal("1e-25"));
        assertThat(validator.validate(rate)).isNotEmpty();
    }
    @Test void summaryOnlyPreparationDoesNotReplaceAnUnknownPriceOrRecalculateOldTotal() {
        var source=new Goods();source.setPrice(new BigDecimal("999.123456789012345678901234"));
        var row=new GoodsBomItem();row.setComponent(source);row.setQty(new BigDecimal("1.00001"));row.setPrice(null);row.setTotal(null);
        var service=new GoodsBomService(mock(com.uten.imp.application.port.BusinessNumericInputEvidencePort.class),mock(GoodsRepository.class),mock(GoodsBomItemRepository.class),mock(com.uten.imp.features.master.color.ColorRepository.class),mock(com.uten.imp.features.master.unit.UnitRepository.class),mock(com.uten.imp.security.TxSessionVars.class),mock(com.uten.imp.security.SecurityContextCurrentUser.class),mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),mock(GoodsMasterRelationshipResolver.class),mock(com.uten.imp.application.port.BusinessEventPublisher.class),mock(com.uten.imp.features.master.lifecycle.MasterObjectAccess.class));
        var request=new com.uten.imp.features.master.goods.dto.BomItemSaveRequest();request.setComponentGoodsId(source.getId());request.setSummary("只改备注");
        service.apply(request,row,source);assertThat(row.getPrice()).isNull();assertThat(row.getTotal()).isNull();assertThat(row.getPendingAmount()).isNull();
        row.setPrice(new BigDecimal("0.123456"));row.setTotal(new BigDecimal("0.12"));
        service.apply(request,row,source);assertThat(row.getPrice()).isEqualByComparingTo("0.123456");assertThat(row.getTotal()).isEqualByComparingTo("0.12");assertThat(row.getPendingAmount()).isNull();
    }
    @Test void actualLearnedDefaultDtosSerializeTheCompletePriceAndCommercialContext()throws Exception {
        var tax=new BigDecimal("13.123456789012345678901234");var rate=new BigDecimal("7.123456789012345678901234");
        var context=new com.uten.imp.features.purchase.common.ProcurementDefaultPriceContext(java.util.UUID.randomUUID(),null,java.util.UUID.randomUUID(),java.util.UUID.randomUUID(),tax);
        var price=new BigDecimal(FULL);
        var purchase=new com.uten.imp.features.purchase.order.PurchaseOrderService.MasterDefaultTermsPerGoods(context.supplierId(),null,context.currencyId(),rate,tax,price,context,null,null);
        var subcontract=new com.uten.imp.features.subcontract.order.SubcontractOrderService.MasterDefaultTermsPerGoods(context.supplierId(),null,context.currencyId(),rate,tax,price,context,null,null);
        var json=new ObjectMapper();var one=json.valueToTree(purchase);var two=json.valueToTree(subcontract);
        assertThat(one.get("purchasePriceExact").asText()).isEqualTo(FULL);
        assertThat(two.get("subcontractPriceExact").asText()).isEqualTo(FULL);
        assertThat(one.get("taxRateExact").asText()).isEqualTo(tax.toPlainString());
        assertThat(one.get("priceContext").get("taxRateExact").asText()).isEqualTo(tax.toPlainString());
    }
    @Test void exactAliasesHaveTheSameMaskAsLegacyFields() {
        var detail=mock(GoodsDetail.class,CALLS_REAL_METHODS);
        detail.setSourceE(new BigDecimal(FULL));detail.setCTotal(new BigDecimal("1e-24"));
        detail.setDiscount(new BigDecimal("0.123456789012345678901234"));
        assertThat(detail.getBudgetExact()).containsEntry("sourceE",FULL).containsEntry("cTotal","0.000000000000000000000001");
        assertThat(detail.getDiscountDisplayText()).isEqualTo("0.123456789012345678901234");
        detail.setCostMasked(true);detail.setDiscountMasked(true);
        assertThat(detail.getBudgetExact()).isEmpty();assertThat(detail.getDiscountDisplayText()).isNull();
    }
}
