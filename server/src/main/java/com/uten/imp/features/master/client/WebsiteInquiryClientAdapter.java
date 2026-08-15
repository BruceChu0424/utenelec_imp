package com.uten.imp.features.master.client;

import com.uten.imp.application.port.WebsiteInquiryClientPort;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.SystemMasterCategoryRegistry;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Optional;
import java.util.UUID;

/** Master-data implementation of the website-inquiry customer boundary. */
@Service
@RequiredArgsConstructor
public class WebsiteInquiryClientAdapter implements WebsiteInquiryClientPort {

    private final ClientRepository repository;
    private final ClientCategoryRepository categoryRepository;
    private final CategoryDrivenCodeService categoryCodes;
    private final SystemMasterCategoryRegistry systemCategories;
    private final TxSessionVars tx;

    @Override
    @Transactional
    public CreatedClient createFromInquiry(CreateRequest request) {
        tx.bind();
        UUID categoryId = systemCategories.clientCategoryId();
        ClientCategory category = categoryRepository.findById(categoryId)
                .filter(candidate -> !candidate.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.INTERNAL, "系统未分类客户分类缺失"));
        Client client = new Client();
        CategoryCodeAllocation code = categoryCodes.allocate(
                CategoryDrivenCodeService.MasterType.CLIENT, category.getId(), null);
        client.setCategory(category);
        client.setCode(code.code());
        client.setCodeSequence(code.sequence());
        client.setCodePrefixCategoryId(code.prefixCategoryId());
        client.setCodeManaged(code.managed());
        client.setName(request.name());
        client.setLinkman(request.contactName());
        client.setMobile(request.phone());
        client.setPhone(request.phone());
        client.setEmail(request.email());
        client.setPlaceId(request.market());
        client.setOwnerEmployeeId(request.ownerEmployeeId());
        client.setStatus("使用");
        client.setRemark("来源：官网询盘 " + request.sourceId());
        Client saved = repository.save(client);
        return new CreatedClient(saved.getId(), saved.getName());
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<String> findName(UUID clientId) {
        return repository.findById(clientId).map(Client::getName);
    }
}
