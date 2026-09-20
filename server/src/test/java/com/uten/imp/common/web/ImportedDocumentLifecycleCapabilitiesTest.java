package com.uten.imp.common.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.*;

class ImportedDocumentLifecycleCapabilitiesTest {
    @Test void bothReceiptFamiliesKeepExactUnknownValuesAndLegacyLifecycleCannotRestart() throws Exception {
        for(Class<?> type:List.of(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail.class,
                com.uten.imp.features.subcontract.receipt.dto.ReceiptDetail.class)) {
            var constructor=type.getConstructors()[0];
            Object[] arguments=Arrays.stream(constructor.getParameterTypes()).map(p->p==boolean.class?false:null).toArray();
            Object detail=constructor.newInstance(arguments);
            ReflectionTestUtils.setField(detail,"legacyId",901);
            ReflectionTestUtils.setField(detail,"totalOriginal",new BigDecimal("9007199254740993.1234"));
            for(short status:new short[]{0,1,-1}) {
                ReflectionTestUtils.setField(detail,"status",status);
                var json=new ObjectMapper().valueToTree(detail);
                assertThat(json.get("legacyImported").booleanValue()).isTrue();
                for(String capability:List.of("canEdit","canDelete","canApprove","canReverse"))assertThat(json.get(capability).booleanValue()).isFalse();
                assertThat(json.get("totalOriginalExact").textValue()).isEqualTo("9007199254740993.1234");
                assertThat(json.get("totalLocalExact").isNull()).isTrue();
                assertThat(json.get("exchangeRateExact").isNull()).isTrue();
            }
            ReflectionTestUtils.setField(detail,"legacyId",null);ReflectionTestUtils.setField(detail,"status",(short)0);
            var nativeJson=new ObjectMapper().valueToTree(detail);
            assertThat(nativeJson.get("legacyImported").booleanValue()).isFalse();
            assertThat(nativeJson.get("canEdit").booleanValue()).isTrue();
            assertThat(nativeJson.get("canApprove").booleanValue()).isTrue();
            assertThatCode(()->ImportedDocumentLifecycleCapabilities.requireMutable(null)).doesNotThrowAnyException();
            assertThatThrownBy(()->ImportedDocumentLifecycleCapabilities.requireMutable(901)).isInstanceOf(ApiException.class);
        }
    }
}
