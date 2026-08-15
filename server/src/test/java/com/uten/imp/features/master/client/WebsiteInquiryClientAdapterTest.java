package com.uten.imp.features.master.client;

import com.uten.imp.application.port.WebsiteInquiryClientPort;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.features.master.SystemMasterCategoryRegistry;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class WebsiteInquiryClientAdapterTest {

    @Test
    void conversionBindsProtectedUncategorizedRootAndKeepsKhFallbackNumbering() {
        UUID categoryId = UUID.randomUUID();
        UUID ownerEmployeeId = UUID.randomUUID();
        ClientCategory category = new ClientCategory();
        category.setId(categoryId);
        category.setName("未分类");

        ClientRepository clients = mock(ClientRepository.class);
        ClientCategoryRepository categories = mock(ClientCategoryRepository.class);
        CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
        SystemMasterCategoryRegistry systemCategories = mock(SystemMasterCategoryRegistry.class);
        when(systemCategories.clientCategoryId()).thenReturn(categoryId);
        when(categories.findById(categoryId)).thenReturn(Optional.of(category));
        when(codes.allocate(CategoryDrivenCodeService.MasterType.CLIENT, categoryId, null))
                .thenReturn(new CategoryCodeAllocation("KH000042", 42L, null, true));
        when(clients.save(any(Client.class))).thenAnswer(invocation -> invocation.getArgument(0));

        WebsiteInquiryClientAdapter adapter = new WebsiteInquiryClientAdapter(
                clients, categories, codes, systemCategories, mock(TxSessionVars.class));
        WebsiteInquiryClientPort.CreatedClient result = adapter.createFromInquiry(
                new WebsiteInquiryClientPort.CreateRequest(
                        "询盘公司", "张三", "13800000000", "inquiry@example.com",
                        "CN", ownerEmployeeId, "website-42"));

        var saved = org.mockito.ArgumentCaptor.forClass(Client.class);
        verify(clients).save(saved.capture());
        assertThat(saved.getValue().getCategory()).isSameAs(category);
        assertThat(saved.getValue().getCode()).isEqualTo("KH000042");
        assertThat(saved.getValue().getCodePrefixCategoryId()).isNull();
        assertThat(saved.getValue().getOwnerEmployeeId()).isEqualTo(ownerEmployeeId);
        assertThat(result.id()).isEqualTo(saved.getValue().getId());
    }
}
