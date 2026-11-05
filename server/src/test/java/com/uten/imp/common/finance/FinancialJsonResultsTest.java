package com.uten.imp.common.finance;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.cfg.JsonNodeFeature;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

class FinancialJsonResultsTest {
    private static final String LARGE="1234567890123456789012345678901234567890.123456789012345678901234";
    private static final String HUGE="1234567890123456789012345678901234567890";
    private static final String TINY="0.000000000000000000000001";
    private static final String RAW="{\"amount\":"+LARGE+",\"tiny\":"+TINY+",\"trailing\":1.2300,\"zero\":0.0000,\"count\":1,\"version\":2147483648,\"huge\":"+HUGE+"}";

    @Test void treeKeepsFullFiniteValuesTheirScaleAndNaturalIntegerNodes()throws Exception {
        var tree=FinancialJsonResults.tree(new ObjectMapper(),RAW);
        assertThat(tree.path("amount").decimalValue().toPlainString()).isEqualTo(LARGE);
        assertThat(tree.path("tiny").decimalValue().toPlainString()).isEqualTo(TINY);
        assertThat(tree.path("trailing").decimalValue().toPlainString()).isEqualTo("1.2300");
        assertThat(tree.path("zero").decimalValue().scale()).isEqualTo(4);
        assertThat(tree.path("count").isInt()).isTrue();assertThat(tree.path("version").isLong()).isTrue();
        assertThat(tree.path("huge").isBigInteger()).isTrue();assertThat(tree.path("huge").bigIntegerValue()).isEqualTo(new BigInteger(HUGE));
    }

    @Test void objectKeepsDecimalsAndAutomaticIntegerWidthsWithoutForcingVersionsToBigInteger()throws Exception {
        var result=FinancialJsonResults.object(new ObjectMapper(),RAW);
        assertThat(result.get("amount")).isEqualTo(new BigDecimal(LARGE));
        assertThat(result.get("tiny")).isEqualTo(new BigDecimal(TINY));
        assertThat(result.get("trailing")).isEqualTo(new BigDecimal("1.2300"));
        assertThat(result.get("count")).isInstanceOf(Integer.class).isEqualTo(1);
        assertThat(result.get("version")).isInstanceOf(Long.class).isEqualTo(2147483648L);
        assertThat(result.get("huge")).isInstanceOf(BigInteger.class).isEqualTo(new BigInteger(HUGE));
    }

    @Test void typedAndGenericReadersRetainTheConfiguredModulesAndExactNestedAmounts()throws Exception {
        var mapper=new ObjectMapper().findAndRegisterModules();UUID actor=UUID.randomUUID();
        var typed=FinancialJsonResults.value(mapper,"{\"actor\":\""+actor+"\",\"date\":\"2026-11-05\",\"amount\":"+LARGE+",\"version\":2147483648}",Result.class);
        assertThat(typed).isEqualTo(new Result(actor,LocalDate.of(2026,11,5),new BigDecimal(LARGE),2147483648L));
        var generic=FinancialJsonResults.value(mapper,"{\"lines\":["+LARGE+","+TINY+"]}",new TypeReference<Map<String,List<BigDecimal>>>() { });
        assertThat(generic.get("lines")).containsExactly(new BigDecimal(LARGE),new BigDecimal(TINY));
    }

    @Test void readerConfigurationDoesNotMutateTheOriginalMapperOrWriterPolicy()throws Exception {
        var mapper=new ObjectMapper();assertThat(mapper.isEnabled(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)).isFalse();
        var source=mapper.getDeserializationConfig();
        FinancialJsonResults.tree(mapper,RAW);
        assertThat(mapper.getDeserializationConfig()).isSameAs(source);
        assertThat(mapper.isEnabled(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)).isFalse();
        assertThat(FinancialJsonResults.reader(mapper).isEnabled(JsonNodeFeature.STRIP_TRAILING_BIGDECIMAL_ZEROES)).isFalse();
        assertThat(mapper.readTree("{\"ordinary\":0.1}").path("ordinary").isDouble()).isTrue();
    }

    @Test void corruptStoredJsonFailsInsteadOfManufacturingAnEmptyOrZeroSuccess() {
        assertThatThrownBy(()->FinancialJsonResults.tree(new ObjectMapper(),"{\"amount\":}"))
                .isInstanceOf(JsonProcessingException.class);
        assertThatThrownBy(()->FinancialJsonResults.object(new ObjectMapper(),"not-json"))
                .isInstanceOf(JsonProcessingException.class);
    }

    private record Result(UUID actor,LocalDate date,BigDecimal amount,long version) { }
}
