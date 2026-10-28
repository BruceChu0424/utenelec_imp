package com.uten.imp.support;

import java.util.LinkedHashMap;
import java.util.Map;

/** String-key fixture pairs: preserve insertion order, null values and mutable rows. */
public final class KeyValueTestData {
    private KeyValueTestData() { }

    public static Map<String, Object> map(Object... pairs) {
        if (pairs.length % 2 != 0) {
            throw new IllegalArgumentException("Fixture values must contain complete key/value pairs");
        }
        Map<String, Object> values = new LinkedHashMap<>();
        for (int index = 0; index + 1 < pairs.length; index += 2) {
            values.put((String) pairs[index], pairs[index + 1]);
        }
        return values;
    }
}
