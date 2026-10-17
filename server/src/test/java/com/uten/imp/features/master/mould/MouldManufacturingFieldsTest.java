package com.uten.imp.features.master.mould;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.DepartmentNameResolver;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.mould.dto.MouldQueryFilter;
import com.uten.imp.features.master.mould.dto.MouldSaveRequest;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.mouldcategory.MouldCategoryRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class MouldManufacturingFieldsTest {
    private final MouldRepository repository = mock(MouldRepository.class);
    private final MouldCategoryRepository categories = mock(MouldCategoryRepository.class);
    private final CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
    private final MouldService service = new MouldService(repository, categories, mock(TxSessionVars.class),
            mock(EntityManager.class), codes, mock(DepartmentNameResolver.class), mock(EmployeeNameResolver.class));
    private final MouldCategory category = new MouldCategory();

    @AfterEach
    void clearAuthentication() { SecurityContextHolder.clearContext(); }

    @Test
    void saveReadListAndExportKeepMonthAndManufacturer() {
        authenticate();
        category.setName("Q7系列");
        category.setRemark("旧模具分类备注");
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocate(any(), any(), any())).thenReturn(new CategoryCodeAllocation("MJ001", 1, null, true));
        when(codes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenReturn(new CategoryCodeAllocation("MJ001", 1, null, true));
        MouldSaveRequest request = request();
        request.setMstatus("2008年7月");
        request.setManufacturer("  模具制造商  ");
        var created = service.create(request);
        var saved = org.mockito.ArgumentCaptor.forClass(Mould.class);
        verify(repository).save(saved.capture());
        Mould mould = saved.getValue();
        when(repository.findById(mould.getId())).thenReturn(Optional.of(mould));
        assertThat(created.getMstatus()).isEqualTo("2008-07");
        assertThat(created.getManufacturer()).isEqualTo("模具制造商");
        assertThat(service.detail(mould.getId()).getManufacturer()).isEqualTo("模具制造商");

        request.setMstatus("2009-03-31"); // 兼容旧客户端，但业务仍按月份保存。
        service.update(mould.getId(), request);
        assertThat(mould.getMstatus()).isEqualTo("2009-03");
        when(repository.findAll(org.mockito.ArgumentMatchers.<Specification<Mould>>any(), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(mould)));
        var filter = new MouldQueryFilter(null, null, Set.of(), null, null, null, null, null, null, null);
        assertThat(service.list(filter, 1, 20).getItems().getFirst().getManufacturer()).isEqualTo("模具制造商");
        assertThat(service.list(filter, 1, 20).getItems().getFirst().getCategoryName()).isEqualTo("Q7系列");
        var export = service.export(filter, 100);
        assertThat(export.columns()).anyMatch(column -> "manufacturer".equals(column.key()));
        assertThat(export.rows().getFirst()).containsEntry("manufacturer", "模具制造商")
                .containsEntry("mstatus", "2009-03")
                .containsEntry("categoryName", "Q7系列");
        assertThat(export.columns()).anyMatch(column -> "categoryName".equals(column.key()) && "系列 / 分类".equals(column.label()));
    }

    @Test
    void oldClientOmissionPreservesManufacturerAndUntouchedLegacyMonthWhileExplicitClearWorks() throws Exception {
        authenticate();
        Mould mould = new Mould();
        mould.setCategory(category);
        mould.setCode("MJ001");
        mould.setCodeSequence(1L);
        mould.setMstatus("约1995年前");
        mould.setManufacturer("已有制造商");
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(repository.findById(mould.getId())).thenReturn(Optional.of(mould));
        when(codes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenReturn(new CategoryCodeAllocation("MJ001", 1, null, true));
        MouldSaveRequest oldClient = request();
        oldClient.setMstatus(mould.getMstatus());
        service.update(mould.getId(), oldClient);
        assertThat(mould.getMstatus()).isEqualTo("约1995年前");
        assertThat(mould.getManufacturer()).isEqualTo("已有制造商");

        var clear = new ObjectMapper().readValue("{\"manufacturer\":null,\"mstatus\":null}", MouldSaveRequest.class);
        clear.setCategoryId(category.getId());
        clear.setName("模具");
        service.update(mould.getId(), clear);
        assertThat(mould.getManufacturer()).isNull();
        assertThat(mould.getMstatus()).isNull();
    }

    @Test
    void invalidAndOverflowMonthsAreRejectedInsteadOfRollingIntoAnotherMonth() {
        for (String raw : List.of("2008-13", "2008-02-31", "1899-12", "2101-01", "不明日期")) {
            assertThatThrownBy(() -> MouldManufacturingMonth.normalize(raw, null))
                    .isInstanceOf(ApiException.class).hasMessageContaining("制造年月");
        }
        assertThat(MouldManufacturingMonth.normalize("2000-02-29", null)).isEqualTo("2000-02");
    }

    @Test
    void oldAliasAndCanonicalJsonRequestsSaveAndReadBackThroughTheSameMonthContract() throws Exception {
        authenticate();
        var json = new ObjectMapper();
        var stored = new HashMap<UUID, Mould>();
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocate(any(), any(), any())).thenReturn(new CategoryCodeAllocation("MJ001", 1, null, true));
        when(codes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenReturn(new CategoryCodeAllocation("MJ001", 1, null, true));
        when(repository.save(any(Mould.class))).thenAnswer(invocation -> {
            Mould value = invocation.getArgument(0);
            stored.put(value.getId(), value);
            return value;
        });
        when(repository.findById(any(UUID.class))).thenAnswer(invocation ->
                Optional.ofNullable(stored.get(invocation.getArgument(0))));

        for (var fixture : List.of(
                Map.entry("mfgMonth", "1998年7月"),
                Map.entry("mfgMonth", "1999-08-31"),
                Map.entry("mstatus", "2000-09"))) {
            String expected = switch (fixture.getValue()) {
                case "1998年7月" -> "1998-07";
                case "1999-08-31" -> "1999-08";
                default -> "2000-09";
            };
            String source = json.writeValueAsString(Map.of(
                    "categoryId", category.getId(), "name", "升级兼容模具",
                    fixture.getKey(), fixture.getValue(), "manufacturer", "已有制造商"));
            var request = json.readValue(source, MouldSaveRequest.class);
            assertThat(request.getMstatus()).as("JSON 字段 %s", fixture.getKey()).isEqualTo(fixture.getValue());
            var created = service.create(request);
            assertThat(service.detail(created.getId()).getMstatus()).isEqualTo(expected);

            // 同一记录先由新客户端更新，再由该版本请求保存，不能清空或降为日精度。
            var canonical = json.readValue(json.writeValueAsString(Map.of(
                    "categoryId", category.getId(), "name", "升级兼容模具", "mstatus", "2001-02")),
                    MouldSaveRequest.class);
            service.update(created.getId(), canonical);
            service.update(created.getId(), request);
            var readBack = service.detail(created.getId());
            assertThat(readBack.getMstatus()).isEqualTo(expected);
            assertThat(readBack.getManufacturer()).isEqualTo("已有制造商");
            var serialized = json.valueToTree(readBack);
            assertThat(serialized.get("mstatus").asText()).isEqualTo(expected);
            assertThat(serialized.has("mfgMonth")).isFalse();
        }
    }

    @Test
    void omittedOrEmptyLegacyMonthPreservesHistoryWhileCanonicalClearAndPriorityAreExplicit() throws Exception {
        authenticate();
        var json = new ObjectMapper();
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenReturn(new CategoryCodeAllocation("MJ001", 1, null, true));
        for (MonthPayload fixture : List.of(
                new MonthPayload("", "1995年7月", false),
                new MonthPayload("\"mfgMonth\":null", "1995年7月", false),
                new MonthPayload("\"mfgMonth\":\"\"", "1995年7月", false),
                new MonthPayload("\"mfgMonth\":\"   \"", "1995年7月", false),
                new MonthPayload("\"mstatus\":null", null, true),
                new MonthPayload("\"mstatus\":\"\"", null, true),
                new MonthPayload("\"mstatus\":\"   \"", null, true),
                new MonthPayload("\"mfgMonth\":\"2008年7月\"", "2008-07", true),
                new MonthPayload("\"mfgMonth\":\"2008-07-31\"", "2008-07", true),
                new MonthPayload("\"mfgMonth\":\"2008年7月\",\"mstatus\":\"2009-03\"", "2009-03", true),
                new MonthPayload("\"mstatus\":\"2009-03\",\"mfgMonth\":\"2008年7月\"", "2009-03", true),
                new MonthPayload("\"mfgMonth\":\"2008年7月\",\"mstatus\":null", null, true),
                new MonthPayload("\"mstatus\":null,\"mfgMonth\":\"2008年7月\"", null, true),
                new MonthPayload("\"mfgMonth\":\"2008年7月\",\"mstatus\":\" \"", null, true),
                new MonthPayload("\"mstatus\":\" \",\"mfgMonth\":\"2008年7月\"", null, true),
                new MonthPayload("\"mfgMonth\":null,\"mstatus\":\"2009-03\"", "2009-03", true),
                new MonthPayload("\"mstatus\":\"2009-03\",\"mfgMonth\":null", "2009-03", true))) {
            Mould mould = existingMonthMould("1995年7月");
            String source = "{\"categoryId\":\"" + category.getId() + "\",\"name\":\"更新模具\",\"remark\":\"仅改备注\""
                    + (fixture.fields().isEmpty() ? "" : "," + fixture.fields()) + "}";
            var request = json.readValue(source, MouldSaveRequest.class);
            assertThat(request.isMstatusProvided()).as(source).isEqualTo(fixture.provided());
            service.update(mould.getId(), request);
            var readBack = service.detail(mould.getId());
            assertThat(readBack.getMstatus()).as(source).isEqualTo(fixture.expected());
            assertThat(readBack.getManufacturer()).as("省略制造商仍保留").isEqualTo("已有制造商");
            assertThat(readBack.getName()).isEqualTo("更新模具");
            assertThat(readBack.getRemark()).isEqualTo("仅改备注");
            assertThat(readBack.getQty()).as("其它字段仍沿用原全覆盖语义").isNull();
            assertThat(json.valueToTree(request).has("mfgMonth")).isFalse();
        }
    }

    @Test
    void canonicalInvalidMonthCannotFallBackToTheLegacyValueInEitherJsonOrder() throws Exception {
        authenticate();
        var json = new ObjectMapper();
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        for (String fields : List.of(
                "\"mfgMonth\":\"2008年7月\",\"mstatus\":\"2009-13\"",
                "\"mstatus\":\"2009-13\",\"mfgMonth\":\"2008年7月\"")) {
            Mould mould = existingMonthMould("1995年7月");
            String source = "{\"categoryId\":\"" + category.getId() + "\",\"name\":\"模具\"," + fields + "}";
            var request = json.readValue(source, MouldSaveRequest.class);
            assertThatThrownBy(() -> service.update(mould.getId(), request)).isInstanceOf(ApiException.class)
                    .hasMessageContaining("制造年月");
            assertThat(service.detail(mould.getId()).getMstatus()).isEqualTo("1995年7月");
        }
    }

    private record MonthPayload(String fields, String expected, boolean provided) { }

    private Mould existingMonthMould(String month) {
        var mould = new Mould();
        mould.setCategory(category);
        mould.setCode("MJ001");
        mould.setCodeSequence(1L);
        mould.setMstatus(month);
        mould.setManufacturer("已有制造商");
        mould.setQty("1+1");
        when(repository.findById(mould.getId())).thenReturn(Optional.of(mould));
        return mould;
    }

    private MouldSaveRequest request() {
        var request = new MouldSaveRequest();
        request.setCategoryId(category.getId());
        request.setName("模具");
        return request;
    }

    private static void authenticate() {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("test", "n/a", "mould:edit"));
    }
}
