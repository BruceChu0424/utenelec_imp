package com.uten.imp.features.sales.template;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.columns.ExtraColumnSnapshot;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.quote.SalesQuoteService;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.quote.dto.QuoteItemDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;
import java.util.zip.ZipInputStream;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SalesQuoteTemplateServiceTest {
    private final SalesQuoteService quotes = mock(SalesQuoteService.class);
    private final SalesQuoteTemplateStore templates = mock(SalesQuoteTemplateStore.class);
    private final MasterIntakeLookupPort master = mock(MasterIntakeLookupPort.class);
    private final NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final AuditService audit = mock(AuditService.class);
    private final UUID quoteId = UUID.randomUUID();
    private final UUID clientId = UUID.randomUUID();
    private final SalesQuoteTemplateService service = new SalesQuoteTemplateService(quotes, templates, master, jdbc, current,
            new WorkbookDownloadService(), audit);
    private QuoteDetail quote;

    @BeforeEach void setup() {
        allow(Set.of("sales_quote:view", "sales_quote:export", "sales_order:price:view"));
        quote = new QuoteDetail(); quote.setId(quoteId); quote.setClientId(clientId); quote.setBillNo("BJ/2026");
        quote.setTotalOriginal(new BigDecimal("19.25"));
        QuoteItemDto item = new QuoteItemDto(); item.setId(UUID.randomUUID()); item.setGoodsId(UUID.randomUUID());
        item.setGoodsNameSnapshot("历史货品"); item.setGoodsNameEn("HISTORICAL NAME"); item.setGoodsCodeSnapshot("P001");
        item.setQty(new BigDecimal("2")); item.setPrice(new BigDecimal("10")); item.setDiscount(new BigDecimal(".85"));
        item.setAmountOriginal(new BigDecimal("19.25"));
        item.setExtraColumns(List.of(new ExtraColumnSnapshot(UUID.randomUUID(), "Insurance", "AMOUNT", "ADD", "2.25")));
        quote.setItems(List.of(item));
        when(quotes.detail(quoteId)).thenReturn(quote);
        var profile = mock(MasterIntakeLookupPort.ClientProfile.class); when(profile.nameEn()).thenReturn("CURRENT CLIENT");
        when(master.clientProfile(clientId)).thenReturn(profile);
        when(master.goodsByIds(any())).thenReturn(List.of(new MasterIntakeLookupPort.GoodsRow(item.getGoodsId(), "CHANGED", "主档新名", null,
                null, null, null, null, null, null, "CHANGED ENGLISH", null, BigDecimal.TEN, "使用")));
        when(templates.list(clientId)).thenReturn(List.of());
        when(jdbc.query(anyString(), anyMap(), org.mockito.ArgumentMatchers.<org.springframework.jdbc.core.RowMapper<String>>any()))
                .thenReturn(List.of("CNY"));
    }

    @Test void defaultExportUsesSavedNamesAmountsAndAdditionalFees() throws Exception {
        var download = export( null);
        assertThat(download.fileName()).isEqualTo("BJ_2026.xlsx");
        try (var wb = WorkbookFactory.create(new ByteArrayInputStream(download.bytes()))) {
            var sheet = wb.getSheetAt(0); var row = sheet.getRow(5);
            assertThat(row.getCell(0).getStringCellValue()).isEqualTo("历史货品");
            assertThat(row.getCell(1).getStringCellValue()).isEqualTo("HISTORICAL NAME");
            assertThat(row.getCell(2).getStringCellValue()).isEqualTo("P001");
            assertThat(row.getCell(6).getNumericCellValue()).isEqualTo(10);
            assertThat(row.getCell(7).getNumericCellValue()).isEqualTo(.85);
            assertThat(row.getCell(8).getNumericCellValue()).isEqualTo(19.25);
            assertThat(sheet.getRow(4).getCell(10).getStringCellValue()).isEqualTo("Insurance (CNY)");
            assertThat(row.getCell(10).getStringCellValue()).isEqualTo("2.25");
        }
        verify(audit).logExplicit(any(), any(), eq("export_sales_quote"), eq("sales_quotes"), eq(quoteId.toString()), any());
    }

    @Test void defaultExportKeepsSameNamedFeesAndNativeAmountSeparateByIdentity() throws Exception {
        var first = new ExtraColumnSnapshot(UUID.randomUUID(), "Insurance", "AMOUNT", "ADD", "2.25");
        var second = new ExtraColumnSnapshot(UUID.randomUUID(), "Insurance", "AMOUNT", "SUBTRACT", ".75");
        var nativeName = new ExtraColumnSnapshot(UUID.randomUUID(), "金额", "AMOUNT", "ADD", "3");
        quote.getItems().getFirst().setExtraColumns(List.of(first, second, nativeName));
        var download = export( null);
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(download.bytes()))) {
            var sheet = workbook.getSheetAt(0); var row = sheet.getRow(5);
            assertThat(sheet.getRow(4).getLastCellNum()).isEqualTo((short) 13);
            assertThat(row.getCell(8).getNumericCellValue()).isEqualTo(19.25);
            assertThat(row.getCell(10).getStringCellValue()).isEqualTo("2.25");
            assertThat(row.getCell(11).getStringCellValue()).isEqualTo(".75");
            assertThat(row.getCell(12).getStringCellValue()).isEqualTo("3");
        }
    }

    @Test void projectionKeepsRepeatedFeeNamesInRequestedIdentityOrder() throws Exception {
        var first = new ExtraColumnSnapshot(UUID.randomUUID(), "Insurance", "AMOUNT", "ADD", "2.25");
        var second = new ExtraColumnSnapshot(UUID.randomUUID(), "Insurance", "AMOUNT", "SUBTRACT", ".75");
        quote.getItems().getFirst().setExtraColumns(List.of(first, second));
        var requested = projection(Map.of("scope", "sales_quote", "columns", List.of(
                Map.of("key", "extra:" + second.columnId(), "label", "减免"),
                Map.of("key", "amount", "label", "金额"),
                Map.of("key", "extra:" + first.columnId(), "label", "附加"))));
        var download = export( new SalesQuoteTemplateService.ExportRequest(List.of(), false, null, requested));
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(download.bytes()))) {
            var row = workbook.getSheetAt(0).getRow(5);
            assertThat(row.getLastCellNum()).isEqualTo((short) 3);
            assertThat(row.getCell(0).getStringCellValue()).isEqualTo(".75");
            assertThat(row.getCell(1).getNumericCellValue()).isEqualTo(19.25);
            assertThat(row.getCell(2).getStringCellValue()).isEqualTo("2.25");
        }
    }

    @Test void allTemplatesProduceIndividuallyEncryptedFilesInsideZip() throws Exception {
        var candidate = QuoteTemplateWorkbook.defaultTemplate(); UUID first = UUID.randomUUID(), second = UUID.randomUUID();
        when(templates.list(clientId)).thenReturn(List.of(view(first), view(second)));
        when(templates.load(eq(clientId), any(), anyInt())).thenReturn(new SalesQuoteTemplateStore.Stored(candidate.xlsx(), candidate.mapping(),
                candidate.features(), candidate.fingerprint(), "source.xlsx"));
        var download = export( new SalesQuoteTemplateService.ExportRequest(List.of(), true, "pass"));
        assertThat(download.templateCount()).isEqualTo(2); assertThat(download.contentType()).isEqualTo("application/zip");
        int count = 0;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(download.bytes()))) {
            while (zip.getNextEntry() != null) {
                byte[] file = zip.readAllBytes();
                try (var wb = WorkbookFactory.create(new ByteArrayInputStream(file), "pass")) {
                    assertThat(wb.getSheetAt(0).getRow(5).getCell(8).getNumericCellValue()).isEqualTo(19.25);
                }
                count++;
            }
        }
        assertThat(count).isEqualTo(2);
    }

    @Test void requiresBothExportAndPricePermissionAndCustomerScope() {
        allow(Set.of("sales_quote:view", "sales_quote:export"));
        assertThatThrownBy(() -> export( null)).isInstanceOf(ApiException.class);
        verifyNoInteractions(quotes);
        allow(Set.of("sales_quote:view", "sales_quote:export", "sales_order:price:view"));
        when(master.clientProfile(clientId)).thenReturn(null);
        assertThatThrownBy(() -> export( null)).hasMessageContaining("客户不在");
        verifyNoInteractions(templates);
    }

    @Test void anotherCustomerTemplateCannotBeSelectedById() {
        UUID stolen = UUID.randomUUID();
        when(templates.load(clientId, stolen, 1)).thenThrow(new ApiException(ErrorCode.NOT_FOUND, "报价模板不存在或不属于此客户"));
        assertThatThrownBy(() -> export( new SalesQuoteTemplateService.ExportRequest(List.of(stolen), false, null)))
                .hasMessageContaining("不属于此客户");
        verify(templates).load(clientId, stolen, 1);
        verifyNoInteractions(audit);
    }

    @Test void customerTemplateRetainsItsColumnsEvenWhenTheCurrentScreenHasAProjection() throws Exception {
        var candidate = QuoteTemplateWorkbook.defaultTemplate(); UUID template = UUID.randomUUID();
        when(templates.list(clientId)).thenReturn(List.of(view(template)));
        when(templates.load(clientId, template, 1)).thenReturn(new SalesQuoteTemplateStore.Stored(candidate.xlsx(), candidate.mapping(),
                candidate.features(), candidate.fingerprint(), "customer.xlsx"));
        var requested = projection(Map.of("scope", "sales_quote", "columns", List.of(Map.of("key", "qty", "label", "ONLY QTY"))));
        var result = export( new SalesQuoteTemplateService.ExportRequest(List.of(template), false, null, requested));
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(result.bytes()))) {
            var row = workbook.getSheetAt(0).getRow(5);
            assertThat(row.getCell(0).getStringCellValue()).isEqualTo("历史货品");
            assertThat(row.getCell(6).getNumericCellValue()).isEqualTo(10);
            assertThat(row.getCell(8).getNumericCellValue()).isEqualTo(19.25);
            assertThat(row.getLastCellNum()).isGreaterThan((short) 1);
        }
    }

    @Test void explicitTemplateVersionDoesNotSilentlyFollowALaterCustomerLayout() throws Exception {
        UUID id=UUID.randomUUID(); var candidate=QuoteTemplateWorkbook.defaultTemplate();
        when(templates.list(clientId)).thenReturn(List.of(new SalesQuoteTemplateStore.TemplateView(id,"Customer",2,"new.xlsx",OffsetDateTime.now(),2,"xlsx")));
        when(templates.load(clientId,id,1)).thenReturn(new SalesQuoteTemplateStore.Stored(candidate.xlsx(),candidate.mapping(),candidate.features(),candidate.fingerprint(),"old.xlsx"));
        export(new SalesQuoteTemplateService.ExportRequest(List.of(id),false,null,null,quote.getReviewRevision(),Map.of(id,1)));
        verify(templates).load(clientId,id,1);
        verify(templates,never()).load(clientId,id);
    }

    @Test void changedQuoteRevisionAndUnselectedVersionCannotProduceAnExport() {
        quote.setReviewRevision(8);
        assertThatThrownBy(() -> export(new SalesQuoteTemplateService.ExportRequest(List.of(),false,null,null,7,Map.of())))
                .hasMessageContaining("报价已被修改");
        verifyNoInteractions(templates,audit);
        assertThatThrownBy(() -> export(new SalesQuoteTemplateService.ExportRequest(List.of(),false,null,null,8,Map.of(UUID.randomUUID(),1))))
                .hasMessageContaining("版本选择不正确");
        verifyNoInteractions(audit);
    }

    @Test void omittedQuoteOrTemplateVersionCannotBypassTheSelectionFence() {
        assertThatThrownBy(() -> service.export(quoteId,null)).hasMessageContaining("缺少报价版本");
        assertThatThrownBy(() -> service.export(quoteId,new SalesQuoteTemplateService.ExportRequest(List.of(),false,null)))
                .hasMessageContaining("缺少报价版本");
        UUID id=UUID.randomUUID(); when(templates.list(clientId)).thenReturn(List.of(view(id)));
        assertThatThrownBy(() -> service.export(quoteId,new SalesQuoteTemplateService.ExportRequest(List.of(id),false,null,null,0,null)))
                .hasMessageContaining("版本选择不正确");
        verify(templates,never()).load(any(),any(),anyInt());
        verifyNoInteractions(audit);
    }

    @Test void anUnsafeStoredTemplateReportsTheColumnAndHowToRepairItWithoutAnInternalStack() throws Exception {
        UUID id=UUID.randomUUID();var candidate=QuoteTemplateWorkbook.defaultTemplate();byte[] bytes;
        try(var workbook=WorkbookFactory.create(new ByteArrayInputStream(candidate.xlsx()));var out=new java.io.ByteArrayOutputStream()) {
            workbook.getSheetAt(0).setColumnHidden(4,true);workbook.write(out);bytes=out.toByteArray();
        }
        when(templates.list(clientId)).thenReturn(List.of(view(id)));
        when(templates.load(clientId,id,1)).thenReturn(new SalesQuoteTemplateStore.Stored(bytes,candidate.mapping(),candidate.features(),candidate.fingerprint(),"customer.xlsx"));
        assertThatThrownBy(() -> export(new SalesQuoteTemplateService.ExportRequest(List.of(id),false,null)))
                .isInstanceOfSatisfying(ApiException.class,failure -> {
                    assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(failure.getMessage()).contains("映射列已隐藏：E","重新上传学习模板").doesNotContain("Exception","java.");
                });
        verifyNoInteractions(audit);
    }

    @Test void learningRequiresWriteScopeAndExportPermissionsBeforeAccessingCandidate() {
        assertThatThrownBy(() -> service.learningContext(quoteId)).hasMessageContaining("权限");
        verifyNoInteractions(quotes, templates);
        allow(Set.of("sales_quote:view", "sales_quote:export", "sales_order:price:view", "sales_quote:edit"));
        when(master.canLearnClientDocument(clientId)).thenReturn(false);
        assertThatThrownBy(() -> service.adopt(quoteId, new SalesQuoteTemplateService.AdoptRequest(UUID.randomUUID())))
                .hasMessageContaining("此客户");
        verifyNoInteractions(templates);
        when(master.canLearnClientDocument(clientId)).thenReturn(true);
        assertThat(service.learningContext(quoteId).clientId()).isEqualTo(clientId);
    }

    @Test void allTwentyOneLearnedTemplatesCanBeDownloadedWithoutTruncation() throws Exception {
        var candidate = QuoteTemplateWorkbook.defaultTemplate();
        List<SalesQuoteTemplateStore.TemplateView> all = new ArrayList<>();
        for (int i = 0; i < 21; i++) all.add(view(UUID.randomUUID()));
        when(templates.list(clientId)).thenReturn(all);
        when(templates.load(eq(clientId), any(), anyInt())).thenReturn(new SalesQuoteTemplateStore.Stored(candidate.xlsx(), candidate.mapping(),
                candidate.features(), candidate.fingerprint(), "source.xlsx"));
        var result = export( new SalesQuoteTemplateService.ExportRequest(List.of(), true, null));
        int files = 0;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(result.bytes()))) {
            while (zip.getNextEntry() != null) { zip.readAllBytes(); files++; }
        }
        assertThat(files).isEqualTo(21); assertThat(result.templateCount()).isEqualTo(21);
    }

    @Test void exportProjectionUsesTheExactVisibleColumnsAndSnapshotFeeValues() throws Exception {
        var extra = quote.getItems().getFirst().getExtraColumns().getFirst();
        Map<String,Object> projection = Map.of("tableKey", "sales.quote.items", "scope", "view_sales", "columns", List.of(
                Map.of("key", "qty", "label", "当前数量", "width", 80),
                Map.of("key", "extra:" + extra.columnId(), "label", "保险费", "width", 160, "definition", Map.of("value", "999")),
                Map.of("key", "goods", "label", "货品", "width", 240)));
        var result = export( new SalesQuoteTemplateService.ExportRequest(List.of(),false,null,projection(projection)));
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(result.bytes()))) {
            var sheet = workbook.getSheetAt(0);
            assertThat(java.util.stream.StreamSupport.stream(sheet.getRow(4).spliterator(), false).map(org.apache.poi.ss.usermodel.Cell::getStringCellValue).toList())
                    .containsExactly("当前数量", "保险费 (CNY)", "货品");
            assertThat(sheet.getRow(5).getCell(0).getNumericCellValue()).isEqualTo(2);
            assertThat(sheet.getRow(5).getCell(1).getStringCellValue()).isEqualTo("2.25");
            assertThat(sheet.getRow(5).getCell(2).getStringCellValue()).isEqualTo("历史货品");
            assertThat(sheet.getRow(5).getLastCellNum()).isEqualTo((short)3);
        }
    }

    @Test void calculatedProjectionLoadsAuthorizedDefinitionsAndUsesOnlySavedServerFacts() throws Exception {
        var platform = mock(com.uten.imp.common.platformcolumns.PlatformColumnService.class);
        service.setPlatformColumns(platform); UUID computed = UUID.randomUUID();
        when(platform.scopes()).thenReturn(List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.Scope(
                "view_sales", "销售计算", false, true, false, List.of(
                    new com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition("qty", "数量", false),
                    new com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition("amount", "金额", true)),true,true,true)));
        when(platform.evaluateDisplayRows(eq("view_sales"),eq(List.of(computed)),any())).thenReturn(List.of(Map.of(computed,"27")));
        Map<String,Object> projection = Map.of("scope", "view_sales", "columns", List.of(
                Map.of("key", "platform:" + computed, "label", "计算", "width", 120, "definition", Map.of("formula", "malicious"))));
        var result = export(new SalesQuoteTemplateService.ExportRequest(List.of(),false,null,projection(projection)));
        verify(platform).evaluateDisplayRows("view_sales",List.of(computed),List.of(Map.of("qty",new BigDecimal("2"),"amount",new BigDecimal("19.25"))));
        try (var workbook=WorkbookFactory.create(new ByteArrayInputStream(result.bytes()))) {
            assertThat(workbook.getSheetAt(0).getRow(5).getCell(0).getStringCellValue()).isEqualTo("27");
        }
    }

    @Test void projectionCannotInventHiddenResourceFieldsOrChangeItsBusinessScope() {
        var columns=List.of(Map.of("key","bankAccountNo","label","银行账户","width",120));
        assertThatThrownBy(()->export(new SalesQuoteTemplateService.ExportRequest(List.of(),false,null,projection(Map.of("columns",columns)))))
                .hasMessageContaining("没有可导出的字段");
        assertThatThrownBy(()->export(new SalesQuoteTemplateService.ExportRequest(List.of(),false,null,projection(Map.of("scope","master_client","columns",columns)))))
                .hasMessageContaining("不属于销售报价");
    }

    private SalesQuoteTemplateService.Download export(SalesQuoteTemplateService.ExportRequest input) {
        var request=input==null ? new SalesQuoteTemplateService.ExportRequest(List.of(),false,null) : input;
        Map<UUID,Integer> versions=request.templateVersions();
        if (versions==null) {
            versions=new HashMap<>();
            List<UUID> ids=request.all() ? templates.list(clientId).stream().map(SalesQuoteTemplateStore.TemplateView::id).toList()
                    : request.templateIds()==null ? List.of() : request.templateIds();
            for (UUID id:ids) if (id!=null) versions.put(id,1);
        }
        return service.export(quoteId,new SalesQuoteTemplateService.ExportRequest(request.templateIds(),request.all(),request.password(),request.columnProjection(),
                request.expectedRevision()==null ? quote.getReviewRevision() : request.expectedRevision(),versions));
    }

    private static com.uten.imp.common.export.TableColumnProjection projection(Map<String,Object> value) {
        return new com.fasterxml.jackson.databind.ObjectMapper().convertValue(value,com.uten.imp.common.export.TableColumnProjection.class);
    }

    private void allow(Set<String> permissions) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "seller", permissions, false, true, false)));
    }
    private SalesQuoteTemplateStore.TemplateView view(UUID id) {
        return new SalesQuoteTemplateStore.TemplateView(id, "Template", 1, "source.xlsx", OffsetDateTime.now(), 1, "xlsx");
    }
}
