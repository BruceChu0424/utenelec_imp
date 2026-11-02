package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;

/** One strict JSON reader for versioned package contracts across runtimes. */
final class ClientPackageJson {
    private ClientPackageJson() { }
    static JsonNode read(byte[] bytes, ObjectMapper mapper) throws IOException {
        return mapper.copy().enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
                .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS).readTree(bytes);
    }
}
