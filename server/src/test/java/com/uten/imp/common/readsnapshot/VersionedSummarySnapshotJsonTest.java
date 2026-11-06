package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.annotation.JsonUnwrapped;
import com.fasterxml.jackson.core.*;
import com.fasterxml.jackson.databind.*;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import org.junit.jupiter.api.Test;
import java.io.StringWriter;
import java.math.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class VersionedSummarySnapshotJsonTest {
    private final ObjectMapper json=Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
    private static <T> VersionedSummaryPages.Snapshot<T> snapshot(T value) {
        return new VersionedSummaryPages.Snapshot<>(value,"a".repeat(64),"b".repeat(64),"c".repeat(64));
    }
    @Test void mapDetailsAreFlatAndPreserveAllRowsNullsAndExtraSourceFields() throws Exception {
        var source=new LinkedHashMap<String,Object>();source.put("rows",List.of(Map.of("amountExact","9007199254740993.12000"),Map.of("amountExact","9007199254740993.12000")));
        source.put("productGoodsId","source-product");source.put("unknown",null);source.put("extraSource",Map.of("raw","保持原文"));
        String encoded=json.writeValueAsString(snapshot(source));JsonNode value=json.readTree(encoded);
        assertThat(value.has("value")).isFalse();assertThat(value.path("rows").size()).isEqualTo(2);
        assertThat(value.path("productGoodsId").asText()).isEqualTo("source-product");assertThat(value.get("unknown").isNull()).isTrue();
        assertThat(value.path("extraSource").path("raw").asText()).isEqualTo("保持原文");assertThat(source).hasSize(4);
        assertProofKeys(encoded);
    }
    record Product(String productGoodsId,List<Map<String,Object>> rows) { }
    record Window(@JsonUnwrapped VersionedSummaryPages.Snapshot<Product> snapshot,String windowAsOf) { }
    @Test void pojoAndAnOuterUnwrappedWindowUseTheSameFlatEnvelope() throws Exception {
        var input=new Product("source-product",List.of(Map.of("qtyExact","1.0000")));
        JsonNode direct=json.readTree(json.writeValueAsString(snapshot(input)));
        String encoded=json.writeValueAsString(new Window(snapshot(input),"2026-11-06T00:00:00Z"));JsonNode wrapped=json.readTree(encoded);
        assertThat(wrapped.has("snapshot")||wrapped.has("value")).isFalse();assertThat(wrapped.path("productGoodsId")).isEqualTo(direct.path("productGoodsId"));
        assertThat(wrapped.path("rows")).isEqualTo(direct.path("rows"));assertThat(wrapped.path("windowAsOf").asText()).isEqualTo("2026-11-06T00:00:00Z");
        assertProofKeys(encoded);
    }
    @Test void originalNumericTokensRetainUnsafeIntegerAndDecimalScaleWithoutADoubleRoundTrip() throws Exception {
        String encoded=json.writeValueAsString(snapshot(Map.of("integer",new BigInteger("900719925474099312345"),
                "amount",new BigDecimal("9007199254740993.1234567890123456789012340000"),"amountExact","原有Exact不覆盖")));
        assertThat(encoded).contains("900719925474099312345","9007199254740993.1234567890123456789012340000","原有Exact不覆盖");
        try(JsonParser parser=json.createParser(encoded)) {
            assertThat(parser.nextToken()).isEqualTo(JsonToken.START_OBJECT);
            while(parser.nextToken()!=JsonToken.END_OBJECT) {
                String name=parser.currentName();parser.nextToken();
                if(name.equals("integer"))assertThat(parser.getBigIntegerValue()).isEqualTo(new BigInteger("900719925474099312345"));
                if(name.equals("amount"))assertThat(parser.getDecimalValue().scale()).isEqualTo(28);
            }
        }
    }
    @Test void reservedProofKeysAreRejectedBeforeAnyPartialEnvelopeIsWritten() throws Exception {
        StringWriter text=new StringWriter();
        try(JsonGenerator out=json.createGenerator(text)) {
            assertThatThrownBy(()->json.writeValue(out,snapshot(Map.of("rows",List.of(),"readScopeVersion","forged"))))
                    .isInstanceOf(JsonMappingException.class).hasMessageContaining("reserved or duplicate");
        }
        assertThat(text.toString()).isEmpty();
    }
    private void assertProofKeys(String encoded) throws Exception {
        var seen=new HashSet<String>();
        try(JsonParser parser=json.createParser(encoded)) {
            parser.nextToken();while(parser.nextToken()!=JsonToken.END_OBJECT) {
                assertThat(seen.add(parser.currentName())).isTrue();parser.nextToken();parser.skipChildren();
            }
        }
        assertThat(seen).contains("readScopeVersion","readSnapshotRevision","readDataVersion");
    }
}
