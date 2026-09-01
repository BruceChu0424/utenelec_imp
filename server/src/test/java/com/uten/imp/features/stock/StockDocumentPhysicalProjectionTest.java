package com.uten.imp.features.stock;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.introspect.BeanPropertyDefinition;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocItemDto;
import com.uten.imp.features.stock.dto.StockDocListItem;
import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

class StockDocumentPhysicalProjectionTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void warehouseDocumentResponsesDoNotSerializeCostFields() {
        assertThat(serializedProperties(StockDocListItem.class))
                .doesNotContain("totalLocal");
        assertThat(serializedProperties(StockDocDetail.class))
                .doesNotContain("totalOriginal", "totalLocal");
        assertThat(serializedProperties(StockDocItemDto.class))
                .doesNotContain("price", "amountOriginal", "amountLocal");
    }

    private Set<String> serializedProperties(Class<?> type) {
        return mapper.getSerializationConfig()
                .introspect(mapper.constructType(type))
                .findProperties()
                .stream()
                .filter(BeanPropertyDefinition::couldSerialize)
                .map(BeanPropertyDefinition::getName)
                .collect(Collectors.toSet());
    }
}
