package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class AiChatArgumentsTest {
    private final ObjectMapper json = new ObjectMapper();
    private final Map<String,Object> schema = Map.of("type","object","additionalProperties",false,
            "properties",Map.of("keyword",Map.of("type","string","maxLength",10)),"required",List.of("keyword"));
    @Test void declaredScalarIsAllowed() throws Exception {
        assertThatCode(() -> AiChatArguments.validate(json.readTree("{\"keyword\":\"G001\"}"),schema,json)).doesNotThrowAnyException();
    }
    @Test void objectIdsAndScopeParametersCannotBeSmuggledThrough() throws Exception {
        var value=json.readTree("{\"keyword\":\"G001\",\"ownerId\":\"other\"}");
        assertThatThrownBy(() -> AiChatArguments.validate(value,schema,json)).isInstanceOf(ApiException.class);
    }
    @Test void nestedPayloadCannotReplaceString() throws Exception {
        var value=json.readTree("{\"keyword\":{\"sql\":\"SELECT *\"}}");
        assertThatThrownBy(() -> AiChatArguments.validate(value,schema,json)).isInstanceOf(ApiException.class);
    }
    @Test void missingRequiredAndOverlongValuesFailClosed() throws Exception {
        assertThatThrownBy(() -> AiChatArguments.validate(json.readTree("{}"),schema,json)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> AiChatArguments.validate(json.readTree("{\"keyword\":\"12345678901\"}"),schema,json)).isInstanceOf(ApiException.class);
    }
}
