package com.uten.imp.features.master.client;

import com.uten.imp.features.master.client.dto.ClientDictItem;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ClientDictionaryTest {

    @Test
    void keepsDisabledClientsForHistoryButMarksOnlyActiveClientsSelectable() {
        Client active = client("Active client", "C-ACTIVE", "\u4f7f\u7528");
        Client disabled = client("Historical client", "C-DISABLED", "\u7981\u7528");
        ClientRepository repo = mock(ClientRepository.class);
        when(repo.findAll(
                        ArgumentMatchers.<Specification<Client>>any(),
                        any(Sort.class)))
                .thenReturn(List.of(active, disabled));
        ClientService service = new ClientService(repo, null, null, null, null, null);

        List<ClientDictItem> items = service.dict();

        assertThat(items).hasSize(2);
        assertThat(items).anySatisfy(item -> {
            assertThat(item.name()).isEqualTo("Active client");
            assertThat(item.selectable()).isTrue();
        });
        assertThat(items).anySatisfy(item -> {
            assertThat(item.name()).isEqualTo("Historical client");
            assertThat(item.selectable()).isFalse();
        });
    }

    private static Client client(String name, String code, String status) {
        Client client = new Client();
        client.setName(name);
        client.setCode(code);
        client.setStatus(status);
        return client;
    }
}
