package com.uten.imp.features.master.client;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** 客户外文名称(ADR-134): 保存请求带键才改, 不带键保留学习补全的值; 详情与列表回传。 */
class ClientNameEnTest {

    private final ClientRepository clients = mock(ClientRepository.class);
    private final ClientCategoryRepository categories = mock(ClientCategoryRepository.class);
    private final CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
    private final ClientAccessPolicy accessPolicy = mock(ClientAccessPolicy.class);
    private final ClientCategory category = new ClientCategory();
    private final ClientService service = new ClientService(clients, categories, mock(TxSessionVars.class),
            mock(EntityManager.class), codes, accessPolicy, mock(EmployeeRepository.class),
            mock(EmployeeNameResolver.class));

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void saveRequestDistinguishesAMissingKeyFromAnExplicitClear() throws Exception {
        ObjectMapper mapper = new ObjectMapper();
        assertThat(mapper.readValue("{\"name\":\"A\"}", ClientSaveRequest.class).hasNameEn()).isFalse();
        ClientSaveRequest cleared = mapper.readValue("{\"name\":\"A\",\"nameEn\":null}", ClientSaveRequest.class);
        assertThat(cleared.hasNameEn()).isTrue();
        assertThat(cleared.getNameEn()).isNull();
    }

    @Test
    void updateKeepsLearnedNameWhenTheKeyIsMissingAndClearsItWhenBlank() {
        category.setId(UUID.randomUUID());
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenReturn(new CategoryCodeAllocation("KH000001", 1, null, true));
        AuthUser user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "sales", Set.of("client:edit"),
                false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
        Client client = new Client();
        client.setCategory(category);
        client.setName("尼日利亚SUNAS");
        client.setCode("KH000001");
        client.setCodeSequence(1L);
        client.setNameEn("SUNAS ELECTRICAL RESOURCE LTD");
        when(clients.findById(client.getId())).thenReturn(Optional.of(client));

        ClientSaveRequest untouched = request();
        var detail = service.update(client.getId(), untouched);
        assertThat(client.getNameEn()).isEqualTo("SUNAS ELECTRICAL RESOURCE LTD");
        assertThat(detail.getNameEn()).isEqualTo("SUNAS ELECTRICAL RESOURCE LTD");

        ClientSaveRequest renamed = request();
        renamed.setNameEn("  Sunas   Electrical ");
        service.update(client.getId(), renamed);
        assertThat(client.getNameEn()).isEqualTo("Sunas Electrical");

        ClientSaveRequest blank = request();
        blank.setNameEn("   ");
        service.update(client.getId(), blank);
        assertThat(client.getNameEn()).isNull();
    }

    private ClientSaveRequest request() {
        ClientSaveRequest request = new ClientSaveRequest();
        request.setCategoryId(category.getId());
        request.setName("尼日利亚SUNAS");
        return request;
    }
}
