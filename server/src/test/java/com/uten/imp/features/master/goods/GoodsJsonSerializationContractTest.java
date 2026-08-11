package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Constructor;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;

class GoodsJsonSerializationContractTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    @Test
    void listItemEmitsOnlyTheCanonicalCNumberKey() throws Exception {
        assertOnlyCanonicalKey(serializedFieldNames(GoodsListItem.class), "cNumber");
    }

    @Test
    void detailEmitsOnlyCanonicalConsecutiveCapitalKeys() throws Exception {
        List<String> names = serializedFieldNames(GoodsDetail.class);
        assertOnlyCanonicalKey(names, "mWeight");
        assertOnlyCanonicalKey(names, "cTotal");
        assertOnlyCanonicalKey(names, "gTotal");
    }

    private void assertOnlyCanonicalKey(List<String> names, String canonical) {
        List<String> caseInsensitiveMatches = names.stream()
                .filter(name -> name.equalsIgnoreCase(canonical))
                .toList();
        assertEquals(List.of(canonical), caseInsensitiveMatches,
                () -> "JSON key must be unique and case-stable: " + canonical + " in " + names);
    }

    private List<String> serializedFieldNames(Class<?> type) throws Exception {
        Constructor<?> constructor = type.getDeclaredConstructors()[0];
        Object[] arguments = new Object[constructor.getParameterCount()];
        Class<?>[] parameterTypes = constructor.getParameterTypes();
        for (int index = 0; index < parameterTypes.length; index++) {
            if (parameterTypes[index] == boolean.class) {
                arguments[index] = false;
            } else if (parameterTypes[index] == int.class) {
                arguments[index] = 0;
            } else if (parameterTypes[index] == long.class) {
                arguments[index] = 0L;
            }
        }

        String json = objectMapper.writeValueAsString(constructor.newInstance(arguments));
        List<String> names = new ArrayList<>();
        try (JsonParser parser = objectMapper.getFactory().createParser(json)) {
            while (parser.nextToken() != null) {
                if (parser.currentToken() == JsonToken.FIELD_NAME) {
                    names.add(parser.currentName());
                }
            }
        }
        return names;
    }
}
