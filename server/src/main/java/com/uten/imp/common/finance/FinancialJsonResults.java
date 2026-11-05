package com.uten.imp.common.finance;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.ObjectReader;
import com.fasterxml.jackson.databind.cfg.JsonNodeFeature;

import java.util.Map;
import java.util.Objects;

/** Decode stored financial results without binary floating-point intermediates.
 * The caller's modules and integer policy remain intact. Writers, fingerprints,
 * stored JSON and business calculations are outside this reader's responsibility. */
public final class FinancialJsonResults {
    private FinancialJsonResults() { }

    public static ObjectReader reader(ObjectMapper mapper) {
        return Objects.requireNonNull(mapper,"A configured financial mapper is required").reader()
                .with(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
                .with(JsonNodeFeature.USE_BIG_DECIMAL_FOR_FLOATS)
                .without(JsonNodeFeature.STRIP_TRAILING_BIGDECIMAL_ZEROES);
    }

    public static JsonNode tree(ObjectMapper mapper,String stored)throws JsonProcessingException {
        return reader(mapper).readTree(stored);
    }

    public static Map<String,Object> object(ObjectMapper mapper,String stored)throws JsonProcessingException {
        return value(mapper,stored,new TypeReference<Map<String,Object>>() { });
    }

    public static <T>T value(ObjectMapper mapper,String stored,Class<T> type)throws JsonProcessingException {
        return reader(mapper).forType(type).readValue(stored);
    }

    public static <T>T value(ObjectMapper mapper,String stored,TypeReference<T> type)throws JsonProcessingException {
        return reader(mapper).forType(type).readValue(stored);
    }
}
