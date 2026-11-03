package com.uten.imp.features.master.reference;

import com.uten.imp.common.web.MasterSearchContext;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.clientcategory.ClientCategoryService;
import com.uten.imp.features.master.clientcategory.dto.ClientCategoryNode;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.application.port.OrganizationReferencePort;
import com.uten.imp.application.port.DepartmentPickerNode;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.master.materialcategory.dto.MaterialCategoryNode;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryService;
import com.uten.imp.features.master.suppliercategory.dto.SupplierCategoryNode;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Read-only choices belong to the existing document capability; master CRUD and export stay separate. */
@RestController
@RequestMapping("/api/business-references")
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class BusinessMasterReferenceController {
    private final BusinessMasterReferenceAccess access;
    private final SupplierService suppliers;
    private final ClientService clients;
    private final GoodsService goods;
    private final SupplierCategoryService supplierCategories;
    private final ClientCategoryService clientCategories;
    private final MaterialCategoryService goodsCategories;
    private final WarehouseService warehouses;
    private final AccountService accounts;
    private final OrganizationReferencePort departments;

    @GetMapping("/departments")
    public List<DepartmentPickerNode> departments() {
        access.require("department");
        return departments.departmentPickerTree();
    }

    public record WarehouseReference(UUID id, String code, String name, String status, Integer legacyId,
            UUID parentId, String parentName, boolean accountable, boolean lineSide, boolean defective,
            boolean selectableForNew, boolean selectableDefective, UUID workshopDepartmentId, String workshopDepartmentName) { }

    @GetMapping("/warehouses")
    public List<WarehouseReference> warehouses() {
        access.require("warehouse");
        return warehouses.dict().stream().map(w -> new WarehouseReference(w.getId(), w.getCode(), w.getName(),
                w.getStatus(), w.getLegacyId(), w.getParentId(), w.getParentName(), w.isAccountable(),
                w.isLineSide(), w.isDefective(), w.isSelectableForNew(), w.isSelectableDefective(),
                w.getWorkshopDepartmentId(), w.getWorkshopDepartmentName())).toList();
    }

    public record AccountReference(UUID id, String code, String name, Integer legacyId, String accountType,
            UUID currencyId, String currencyCode, String currencyName, java.math.BigDecimal exchangeRate,
            boolean baseCurrency, String status) { }

    @GetMapping("/accounts")
    public List<AccountReference> accounts() {
        access.require("account");
        return accounts.dict().stream().map(a -> new AccountReference(a.getId(), a.getCode(), a.getName(),
                a.getLegacyId(), a.getAccountType(), a.getCurrencyId(), a.getCurrencyCode(), a.getCurrencyName(),
                a.getExchangeRate(), a.isBaseCurrency(), a.getStatus())).toList();
    }

    @GetMapping("/suppliers")
    public PageResponse<PartyReference> suppliers(@RequestParam(required=false) UUID categoryId,
            @RequestParam(required=false) String keyword,@RequestParam(defaultValue="true") boolean selectableOnly,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="100") int size) {
        access.require("supplier");
        return suppliers.referencePage(categoryId, keyword, selectableOnly, page, size);
    }

    public record PartySearch(@jakarta.validation.constraints.Size(max=200) String keyword,
            UUID categoryId, Boolean selectableOnly, Boolean excludeLegacyFinanceStub) { }

    @PostMapping("/suppliers/search")
    public PageResponse<PartyReference> supplierSearchPage(@Valid @RequestBody PartySearch search,
            @RequestParam(required=false) UUID categoryId,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="100") int size) {
        access.require("supplier");
        return suppliers.referencePage(searchCategory(categoryId, search.categoryId()), search.keyword(),
                !Boolean.FALSE.equals(search.selectableOnly()), page, size);
    }

    @PostMapping("/suppliers/search-context")
    public MasterSearchContext supplierSearch(@Valid @RequestBody PartySearch search,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="100") int size) {
        access.require("supplier");
        return suppliers.referenceSearchContext(search.categoryId(), search.keyword(),
                !Boolean.FALSE.equals(search.selectableOnly()), page, size);
    }

    @GetMapping("/clients")
    public PageResponse<PartyReference> clients(@RequestParam(required=false) UUID categoryId,
            @RequestParam(required=false) String keyword,@RequestParam(defaultValue="true") boolean selectableOnly,
            @RequestParam(defaultValue="true") boolean excludeLegacyFinanceStub,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="100") int size) {
        access.require("client");
        return clients.referencePage(categoryId, keyword, selectableOnly, excludeLegacyFinanceStub, page, size);
    }

    @PostMapping("/clients/search-context")
    public MasterSearchContext clientSearch(@Valid @RequestBody PartySearch search,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="100") int size) {
        access.require("client");
        return clients.referenceSearchContext(search.categoryId(), search.keyword(),
                !Boolean.FALSE.equals(search.selectableOnly()), !Boolean.FALSE.equals(search.excludeLegacyFinanceStub()), page, size);
    }

    @PostMapping("/clients/search")
    public PageResponse<PartyReference> clientSearchPage(@Valid @RequestBody PartySearch search,
            @RequestParam(required=false) UUID categoryId,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="100") int size) {
        access.require("client");
        return clients.referencePage(searchCategory(categoryId, search.categoryId()), search.keyword(),
                !Boolean.FALSE.equals(search.selectableOnly()), !Boolean.FALSE.equals(search.excludeLegacyFinanceStub()), page, size);
    }

    private static UUID searchCategory(UUID query, UUID body) {
        if (query != null && body != null && !query.equals(body)) {
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "分类条件不一致");
        }
        return query == null ? body : query;
    }

    @GetMapping("/supplier-categories")
    public List<ReferenceCategory> supplierCategories() {
        access.require("supplier");
        return ReferenceCategory.project(supplierCategories.tree(), SupplierCategoryNode::getId, SupplierCategoryNode::getCode,
                SupplierCategoryNode::getCodePrefix, SupplierCategoryNode::getName, SupplierCategoryNode::getLevel,
                SupplierCategoryNode::getParentId, SupplierCategoryNode::getLegacyId, SupplierCategoryNode::getChildren);
    }

    @GetMapping("/client-categories")
    public List<ReferenceCategory> clientCategories() {
        access.require("client");
        return ReferenceCategory.project(clientCategories.tree(), ClientCategoryNode::getId, ClientCategoryNode::getCode,
                ClientCategoryNode::getCodePrefix, ClientCategoryNode::getName, ClientCategoryNode::getLevel,
                ClientCategoryNode::getParentId, ClientCategoryNode::getLegacyId, ClientCategoryNode::getChildren);
    }

    @GetMapping("/goods/categories")
    public List<ReferenceCategory> goodsCategories() {
        access.require("goods");
        return ReferenceCategory.project(goodsCategories.tree(), MaterialCategoryNode::getId, MaterialCategoryNode::getCode,
                MaterialCategoryNode::getCodePrefix, MaterialCategoryNode::getName, MaterialCategoryNode::getLevel,
                MaterialCategoryNode::getParentId, MaterialCategoryNode::getLegacyId, MaterialCategoryNode::getChildren);
    }

    @GetMapping("/goods")
    public PageResponse<Map<String,Object>> goods(@ModelAttribute GoodsQueryFilter filter,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="100") int size,
            @RequestParam(required=false) String sort,@RequestParam(required=false) String order,
            HttpServletRequest request) {
        access.require("goods");
        var scoped = filter.withColumnSearch(com.uten.imp.common.util.ColumnKeywordSearch.requestValues(request));
        GoodsReferenceProjection.validateQuery(scoped, sort);
        var result = goods.list(scoped, page, size, sort, order);
        boolean includeMasterStock = access.canReadMasterGoods();
        return new PageResponse<>(result.getItems().stream()
                .map(item -> GoodsReferenceProjection.of(item, includeMasterStock)).toList(),
                result.getPage(), result.getSize(), result.getTotal(), result.getTotalPages());
    }

    @GetMapping("/goods/search-category-ids")
    public List<UUID> goodsSearchCategories(@ModelAttribute GoodsQueryFilter filter, HttpServletRequest request) {
        access.require("goods");
        var scoped = filter.withColumnSearch(com.uten.imp.common.util.ColumnKeywordSearch.requestValues(request));
        GoodsReferenceProjection.validateQuery(scoped, null);
        return goods.matchingCategoryIds(scoped);
    }

    @GetMapping("/goods/facet-values")
    public com.uten.imp.features.master.goods.dto.GoodsFacetPage goodsFacetValues(@ModelAttribute GoodsQueryFilter filter,
            @RequestParam String field, @RequestParam(defaultValue="") String search,
            @RequestParam(defaultValue="1") int page, @RequestParam(defaultValue="50") int size,
            HttpServletRequest request) {
        access.require("goods");
        var scoped = filter.withColumnSearch(com.uten.imp.common.util.ColumnKeywordSearch.requestValues(request));
        GoodsReferenceProjection.validateQuery(scoped, null);
        GoodsReferenceProjection.validateField(field);
        return goods.facetValues(scoped, field, search, page, size);
    }

    @GetMapping("/goods/facets")
    public com.uten.imp.features.master.goods.dto.GoodsFacets goodsFacets(@ModelAttribute GoodsQueryFilter filter,
            HttpServletRequest request) {
        access.require("goods");
        var scoped = filter.withColumnSearch(com.uten.imp.common.util.ColumnKeywordSearch.requestValues(request));
        GoodsReferenceProjection.validateQuery(scoped, null);
        return GoodsReferenceProjection.facets(goods.queryFacets(scoped));
    }
}
