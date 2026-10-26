package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.math.BigDecimal;
import java.util.Arrays;
import static org.junit.jupiter.api.Assertions.*;

class GoodsFieldEditPolicyTest {
    private final Goods current = new Goods();
    private final GoodsSaveRequest request = new GoodsSaveRequest();
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    void grant(String... codes) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("actor", "",
                Arrays.stream(codes).map(SimpleGrantedAuthority::new).toList()));
    }
    @Test void generalEditorCannotChangePurchaseOrSalesFields() {
        grant("goods:edit");
        request.setMinOrderQty(BigDecimal.TEN);
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
        request.setMinOrderQty(null); request.setCNumber("客户型号");
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
    }
    @Test void purchaseCanEditPolicyButCannotRenameGoodsOrCustomerModel() {
        grant("goods:purchase:edit");
        request.setMinOrderQty(BigDecimal.TEN);
        assertDoesNotThrow(() -> GoodsFieldEditPolicy.requireChanged(current,request));
        request.setName("越权改名");
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
        request.setName(null); request.setCNumber("越权客户型号");
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
    }
    @Test void salesCanEditCustomerDataButCannotChangePurchasePolicy() {
        grant("goods:sales:edit");
        request.setClientGoodsName("客户名称"); request.setCNumber("客户型号"); request.setNameEn("English name");
        assertDoesNotThrow(() -> GoodsFieldEditPolicy.requireChanged(current,request));
        request.setOrderMultipleQty(new BigDecimal("12"));
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
    }
    @Test void echoedDecimalsAndEmptyStringsDoNotRequireUnchangedGroups() {
        grant("goods:edit");
        current.setMinOrderQty(new BigDecimal("1.0000")); request.setMinOrderQty(BigDecimal.ONE);
        current.setClientGoodsName(null); request.setClientGoodsName("");
        request.setName("允许基础改名");
        assertDoesNotThrow(() -> GoodsFieldEditPolicy.requireChanged(current,request));
    }
    @Test void salesWithCostReadCannotClearCostViaFullPut() {
        grant("goods:sales:edit", "goods:cost:view");
        current.setSourceE(BigDecimal.TEN); request.setSourceE(null);
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
    }
    @Test void whitespaceCannotDisguiseAnUnauthorizedBaseFieldWrite() {
        grant("goods:sales:edit");
        current.setName("货品名称"); request.setName(" 货品名称 ");
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
    }
    @Test void clearingAnUnresolvedLegacyReferenceStillRequiresItsFieldGroup() {
        grant("goods:sales:edit");
        current.setColorLegacyId(17); request.setColorId(null);
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
        current.setColorLegacyId(null); current.setVendLegacyId(19); request.setDefaultSupplierId(null);
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
    }
    @Test void explicitNullStatusIsInvalidAndPriceOrDiscountClearsKeepIndependentAuthority() {
        grant("goods:sales:edit","goods:price:view","goods:discount:view");
        current.setStatus("禁用"); request.setStatus(null);
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
        request.setStatus("禁用"); current.setPrice(BigDecimal.TEN); request.setPrice(null);
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
        request.setPrice(BigDecimal.TEN); current.setDiscount(BigDecimal.ONE); request.setDiscount(null);
        assertThrows(ApiException.class, () -> GoodsFieldEditPolicy.requireChanged(current,request));
    }
}
