package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import jakarta.validation.Validator;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** The optional customer-facing name shares neither identity nor presence with the customer model. */
class GoodsClientGoodsNameServiceTest {
    private final ObjectMapper json = new ObjectMapper();
    private final GoodsRepository repository = mock(GoodsRepository.class);
    private final MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
    private final CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final OwnerVisibility visibility = mock(OwnerVisibility.class);
    private final EntityManager em = mock(EntityManager.class);
    private final MaterialCategory category = new MaterialCategory();
    private GoodsService service;

    @BeforeEach void setUp() {
        login(Set.of("goods:view", "goods:create", "goods:edit"));
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        service = new GoodsService(repository, categories, mock(ColorRepository.class), mock(UnitRepository.class),
                mock(MouldRepository.class), mock(TxSessionVars.class), em, codes,
                visibility, current, mock(GoodsCostMasker.class), mock(GoodsMasterRelationshipResolver.class));
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocateForNewGoods(any(), any(), any())).thenReturn(new CategoryCodeAllocation("HP1", 1, null, true));
        when(codes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenReturn(new CategoryCodeAllocation("HP1", 1, null, true));
    }

    @AfterEach void clearSecurityContext() { SecurityContextHolder.clearContext(); }

    @Test void createAndDetailExposeDistinctCustomerNameCustomerModelAndOwnIdentity() throws Exception {
        GoodsDetail created = service.create(request("\"clientGoodsName\":\"  客户面板名称  \",\"cNumber\":\"  CUSTOMER-X  \","));
        var saved = ArgumentCaptor.forClass(Goods.class);
        verify(repository).save(saved.capture());
        Goods value = saved.getValue();
        when(repository.findById(value.getId())).thenReturn(Optional.of(value));

        assertThat(value.getClientGoodsName()).isEqualTo("客户面板名称");
        assertThat(value.getCNumber()).isEqualTo("CUSTOMER-X");
        assertThat(value.getName()).isEqualTo("内部货品名称");
        assertThat(value.getModel()).isEqualTo("OWN-MODEL");
        for (GoodsDetail detail : List.of(created, service.detail(value.getId()))) {
            JsonNode response = json.valueToTree(detail);
            assertThat(response.get("clientGoodsName").asText()).isEqualTo("客户面板名称");
            assertThat(response.get("cNumber").asText()).isEqualTo("CUSTOMER-X");
            assertThat(response.get("name").asText()).isEqualTo("内部货品名称");
            assertThat(response.get("model").asText()).isEqualTo("OWN-MODEL");
            assertThat(response.has("clientgoodsname")).isFalse();
            assertThat(response.has("cnumber")).isFalse();
        }
    }

    @Test void omissionAndExplicitNullHaveDifferentRequestPresence() throws Exception {
        GoodsSaveRequest omitted = request("");
        GoodsSaveRequest explicitNull = request("\"clientGoodsName\":null,");
        GoodsSaveRequest blank = request("\"clientGoodsName\":\"   \",");
        assertThat(omitted.hasClientGoodsName()).isFalse();
        assertThat(explicitNull.hasClientGoodsName()).isTrue();
        assertThat(blank.hasClientGoodsName()).isTrue();
        assertThat(explicitNull.hasCNumber()).isFalse();
        assertThat(json.valueToTree(explicitNull).has("clientGoodsNamePresent")).isFalse();
    }

    @Test void oldRequestPreservesBothCustomerFieldsAndEachExplicitClearIsIndependent() throws Exception {
        Goods value = existing();
        GoodsDetail oldClientSave = service.update(value.getId(), request(""));
        assertThat(oldClientSave.getClientGoodsName()).isEqualTo("原客户名称");
        assertThat(oldClientSave.getCNumber()).isEqualTo("OLD-CUSTOMER-MODEL");

        service.update(value.getId(), request("\"clientGoodsName\":\"   \","));
        assertThat(value.getClientGoodsName()).isNull();
        assertThat(value.getCNumber()).isEqualTo("OLD-CUSTOMER-MODEL");
        service.update(value.getId(), request("\"clientGoodsName\":\"  新客户名称  \","));
        assertThat(value.getClientGoodsName()).isEqualTo("新客户名称");
        service.update(value.getId(), request("\"cNumber\":null,"));
        assertThat(value.getClientGoodsName()).isEqualTo("新客户名称");
        assertThat(value.getCNumber()).isNull();
        service.update(value.getId(), request("\"clientGoodsName\":null,"));
        assertThat(value.getClientGoodsName()).isNull();
        assertThat(value.getName()).isEqualTo("内部货品名称");
        assertThat(value.getModel()).isEqualTo("OWN-MODEL");
    }

    @Test void staleFullFormCannotMutateEitherCustomerField() throws Exception {
        Goods value = existing();
        value.setVersion(3);
        var failure = assertThrows(ApiException.class, () -> service.update(value.getId(),
                request("\"clientGoodsName\":\"stale name\",\"cNumber\":\"stale model\",\"version\":2,")));
        assertThat(failure.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertOriginalCustomerFields(value);
        verify(repository, never()).save(any());
    }

    @Test void customerNameDoesNotBypassTheExistingEditAuthority() throws Exception {
        Goods value = existing();
        login(Set.of("goods:view"));
        var failure = assertThrows(ApiException.class, () -> service.update(value.getId(),
                request("\"clientGoodsName\":\"forbidden\",")));
        assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        assertOriginalCustomerFields(value);
        verify(repository, never()).save(any());
    }

    @Test void visibleButNotWritableOwnerCannotChangeCustomerName() throws Exception {
        Goods value = existing();
        UUID owner = UUID.randomUUID();
        value.setOwnerEmployeeId(owner);
        ReflectionTestUtils.setField(service, "goodsOwnerScopeEnabled", true);
        when(visibility.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(owner), Set.of()));
        assertThat(service.detail(value.getId()).getClientGoodsName()).isEqualTo("原客户名称");
        var failure = assertThrows(ApiException.class, () -> service.update(value.getId(),
                request("\"clientGoodsName\":\"not writable\",")));
        assertThat(failure.getCode()).isEqualTo(ErrorCode.NOT_FOUND);
        assertOriginalCustomerFields(value);
        verify(repository, never()).save(any());
    }

    @Test void inlineCustomerNamePatchPreservesCustomerModelAndAnUnrelatedPatchPreservesName() throws Exception {
        Goods value = existing(); value.setVersion(7);
        GoodsService commands = mock(GoodsService.class);
        GoodsDetail detail = service.detail(value.getId());
        when(commands.detail(value.getId())).thenReturn(detail);
        var inline = inline(commands, value);
        inline.patch(value.getId(), Map.of("version", json.valueToTree(7)),
                Map.of("clientGoodsName", json.valueToTree("new inline name")));
        inline.patch(value.getId(), Map.of("version", json.valueToTree(7)),
                Map.of("spec", json.valueToTree("new specification")));
        var requests = ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(commands, times(2)).update(eq(value.getId()), requests.capture());
        assertThat(requests.getAllValues().get(0).getClientGoodsName()).isEqualTo("new inline name");
        assertThat(requests.getAllValues().get(0).hasClientGoodsName()).isTrue();
        assertThat(requests.getAllValues().get(0).getCNumber()).isEqualTo("OLD-CUSTOMER-MODEL");
        assertThat(requests.getAllValues().get(1).getClientGoodsName()).isEqualTo("原客户名称");
        verify(commands, times(2)).requireVisible(value);
        verify(commands, times(2)).requireWritable(value);
    }

    @Test void staleInlineCustomerNameIsRejectedBeforeReachingUpdate() throws Exception {
        Goods value = existing(); value.setVersion(7);
        GoodsService commands = mock(GoodsService.class);
        GoodsDetail detail = service.detail(value.getId());
        when(commands.detail(value.getId())).thenReturn(detail);
        var inline = inline(commands, value);
        var failure = assertThrows(ApiException.class, () -> inline.patch(value.getId(),
                Map.of("version", json.valueToTree(6)), Map.of("clientGoodsName", json.valueToTree("stale"))));
        assertThat(failure.getCode()).isEqualTo(ErrorCode.CONFLICT);
        verify(commands, never()).update(any(), any());
        assertOriginalCustomerFields(value);
    }

    @Test void inlineNameRequiresBothViewAndEditBeforeReadingTheRow() {
        Goods value = existing();
        GoodsService commands = mock(GoodsService.class);
        var inline = inline(commands, value);
        login(Set.of("goods:edit"));
        clearInvocations(repository, em);
        var failure = assertThrows(ApiException.class, () -> inline.patch(value.getId(),
                Map.of("version", json.valueToTree(0)), Map.of("clientGoodsName", json.valueToTree("forbidden"))));
        assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        verifyNoInteractions(commands, repository, em);
    }

    @Test void exportPlacesCustomerNameAfterNameAndKeepsCustomerModelAfterOwnModel() {
        var exporting = spy(service);
        GoodsListItem item = mock(GoodsListItem.class);
        when(item.getId()).thenReturn(UUID.randomUUID());
        when(item.getName()).thenReturn("内部货品名称");
        when(item.getClientGoodsName()).thenReturn("客户面板名称");
        when(item.getModel()).thenReturn("OWN-MODEL");
        when(item.getCNumber()).thenReturn("CUSTOMER-X");
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of());
        doReturn(new PageResponse<>(List.of(item), 1, 100, 1, 1))
                .when(exporting).list(isNull(), anyInt(), anyInt(), anyString(), anyString());

        var result = exporting.export(null, "code", "asc", 100);
        assertThat(result.columns()).extracting(ExportColumn::key)
                .startsWith("name", "clientGoodsName", "nameEn", "code");
        var keys = result.columns().stream().map(ExportColumn::key).toList();
        assertThat(keys.indexOf("cNumber")).isEqualTo(keys.indexOf("model") + 1);
        assertThat(result.columns().get(1).label()).isEqualTo("客户货品名称");
        assertThat(result.rows()).singleElement().satisfies(row -> {
            assertThat(row).containsEntry("name", "内部货品名称")
                    .containsEntry("clientGoodsName", "客户面板名称")
                    .containsEntry("model", "OWN-MODEL").containsEntry("cNumber", "CUSTOMER-X");
            assertThat(row).doesNotContainKeys("price", "discount");
        });
    }

    private GoodsInlineEditService inline(GoodsService commands, Goods value) {
        Query lock = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(lock);
        when(lock.setParameter(anyString(), any())).thenReturn(lock);
        when(lock.getResultList()).thenReturn(List.of(value.getId()));
        Validator validator = mock(Validator.class);
        when(validator.validate(any(GoodsSaveRequest.class))).thenReturn(Set.of());
        return new GoodsInlineEditService(commands, repository, em, mock(TxSessionVars.class), current, json, validator);
    }

    private void login(Set<String> permissions) {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "customer-name-editor",
                permissions, false, true, false);
        when(current.get()).thenReturn(Optional.of(actor));
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }

    private GoodsSaveRequest request(String fields) throws Exception {
        return json.readValue("{" + fields + "\"categoryId\":\"" + category.getId()
                + "\",\"name\":\"内部货品名称\",\"model\":\"OWN-MODEL\",\"status\":\"使用\"}", GoodsSaveRequest.class);
    }

    private Goods existing() {
        Goods value = new Goods();
        value.setCategory(category); value.setName("内部货品名称"); value.setModel("OWN-MODEL");
        value.setStatus("使用"); value.setCode("HP1"); value.setCodeSequence(1L);
        value.setClientGoodsName("原客户名称"); value.setCNumber("OLD-CUSTOMER-MODEL");
        when(repository.findById(value.getId())).thenReturn(Optional.of(value));
        return value;
    }

    private void assertOriginalCustomerFields(Goods value) {
        assertThat(value.getClientGoodsName()).isEqualTo("原客户名称");
        assertThat(value.getCNumber()).isEqualTo("OLD-CUSTOMER-MODEL");
    }
}
