package com.uten.imp.features.master.client;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.master.client.dto.ClientDictItem;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ClientDictItemTest {

    @Test
    void dictionaryContractExposesOnlyIdentityAndDisplayFields() {
        ClientDictItem item = new ClientDictItem(UUID.randomUUID(), "C-001", "示例客户", true);

        Map<String, Object> json = new ObjectMapper().convertValue(
                item,
                new TypeReference<>() {
                });

        assertThat(json)
                .containsOnlyKeys("id", "code", "name", "selectable")
                .containsEntry("selectable", true);
    }
}
