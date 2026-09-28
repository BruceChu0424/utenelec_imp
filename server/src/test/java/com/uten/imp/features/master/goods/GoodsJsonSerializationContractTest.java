package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.master.goods.dto.BomItemUsage;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Constructor;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class GoodsJsonSerializationContractTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    /** 真实使用数量(ADR-129)的接口字段：组装信息行与「BOM 学习记录」组件行一字不差。 */
    private static final List<String> USAGE_KEYS = List.of("actualQty", "actualPerUnitQty", "actualStatus",
            "effectiveQty", "usageBasis", "actualSampleCount", "actualOutputQty", "actualNetQty", "actualUpdatedAt",
            "relearnedAt", "systemLearned", "actualDefectQty", "actualPerProducedQty", "actualDefectRate");

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

    /** 组装行的真实使用数量(ADR-129)平铺在行上，字段名即接口契约，不嵌套成 usage 对象。 */
    @Test
    void bomItemViewFlattensTheActualUsageContractKeys() throws Exception {
        List<String> names = serializedFieldNames(BomItemView.class);
        assertTrue(names.contains("qty"), () -> "qty missing in " + names);
        assertFlattensUsage(names);
    }

    /** 「BOM 学习记录」组件行与组装行同一组字段名(同一个 BomItemUsage)，页面只要一个解析。 */
    @Test
    void learningComponentEmitsTheSameActualUsageKeysAsTheBomTab() throws Exception {
        List<String> names = serializedFieldNames(GoodsBomLearningQueryService.Component.class);
        assertTrue(names.contains("designQty"), () -> "designQty missing in " + names);
        assertFlattensUsage(names);
        assertEquals(USAGE_KEYS, serializedFieldNames(BomItemUsage.class),
                "BomItemUsage 加字段时两处接口一起带出，这里的清单同步更新");
    }

    @Test
    void learningSummaryCarriesTheRelearnCapability() throws Exception {
        assertEquals(List.of("profile", "components", "canRelearn"),
                serializedFieldNames(GoodsBomLearningQueryService.Summary.class));
    }

    /** 学习档案带已学良品产量与同一批族的报工不良数(只作说明)。 */
    @Test
    void learningProfileCarriesTheDefectTotalNextToTheGoodOutput() throws Exception {
        assertEquals(List.of("totalOutputQty", "totalDefectQty", "sampleCount", "blockedReason", "outputUnitName"),
                serializedFieldNames(GoodsBomLearningQueryService.Profile.class));
    }

    /** 没有学习数据的边：不良数是 0(不是空)，实产单耗与不良率为空。 */
    @Test
    void usageWithoutLearningDataReportsZeroDefectsAndNoRates() throws Exception {
        var json = objectMapper.readTree(objectMapper.writeValueAsString(BomItemUsage.NONE));
        assertTrue(json.get("actualDefectQty").isNumber(), json::toString);
        assertEquals(0, json.get("actualDefectQty").decimalValue().signum());
        assertTrue(json.get("actualPerProducedQty").isNull(), json::toString);
        assertTrue(json.get("actualDefectRate").isNull(), json::toString);
    }

    private void assertFlattensUsage(List<String> names) {
        for (String key : USAGE_KEYS) {
            assertTrue(names.contains(key), () -> key + " missing in " + names);
        }
        assertFalse(names.contains("usage"), () -> "usage must be unwrapped: " + names);
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
            } else if (parameterTypes[index] == BomItemUsage.class) {
                arguments[index] = BomItemUsage.NONE;
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
