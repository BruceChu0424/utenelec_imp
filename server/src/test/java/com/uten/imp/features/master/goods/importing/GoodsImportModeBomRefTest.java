package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsBomItem;
import com.uten.imp.features.master.goods.GoodsBomItemRepository;
import com.uten.imp.features.master.goods.GoodsBomPasteService;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 导入模式（2026-10-28）与组装信息ID 契约：
 * 新建模式不看系统标识（身份上全部新建，编号占用报错带新建口径提示）；
 * 修改模式只认在库 UUID（缺标识/未匹配/已删除一律报错，不新建不恢复）；
 * 混合模式行为不变（见 GoodsImportMergeTest/GoodsImportRestoreDeletedTest）。
 * 组装信息ID=「货品编号-BOM」：有值即把源货品整棵组装信息复制到本行货品下
 * （新建行 APPEND；已有货品 REPLACE 且预期项来自当前组装行）；指向自身不写。
 */
class GoodsImportModeBomRefTest {
    @AfterEach
    void clearAuthentication() {
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
    }

    // ---------- 模式：新建 ----------

    @Test
    void detect_createModeIgnoresTheSystemIdentifierAndPlansANewRecord() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        UUID liveId = UUID.randomUUID();
        when(goods.findById(liveId)).thenReturn(Optional.of(liveGoods(liveId, "208035801", "已有货品")));
        GoodsImportService service = service(goods, null, null);

        GoodsImportReport report = service.detect(workbook("", "复制货品", "成品", liveId.toString(), null),
                java.util.Map.of(), java.util.Set.of(), java.util.Map.of(), GoodsImportMode.CREATE_ONLY);

        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(1, report.addedRows());
        assertEquals(0, report.restorableRows());
        assertTrue(report.reviewRows().isEmpty());
        assertNotNull(report.planId());
    }

    @Test
    void detect_createModeReportsDuplicateCodeWithTheCreateModeHint() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.existsByCodeAndDeletedFalse("208035801")).thenReturn(true);
        when(goods.findByCodeAndDeletedFalse("208035801")).thenReturn(Optional.empty());
        GoodsImportService service = service(goods, null, null);

        GoodsImportReport report = service.detect(workbook("208035801", "新建货品", "成品", null, null),
                java.util.Map.of(), java.util.Set.of(), java.util.Map.of(), GoodsImportMode.CREATE_ONLY);

        assertEquals(1, report.errors().size());
        assertEquals("编号", report.errors().getFirst().column());
        assertTrue(report.errors().getFirst().message().contains("新建导入请清空或修改该编号"));
    }

    // ---------- 模式：修改 ----------

    @Test
    void detect_updateModeRejectsRowsWithoutASystemIdentifier() throws Exception {
        GoodsImportService service = service(mock(GoodsRepository.class), null, null);

        GoodsImportReport report = service.detect(workbook("208035801", "修改货品", "成品", null, null),
                java.util.Map.of(), java.util.Set.of(), java.util.Map.of(), GoodsImportMode.UPDATE_ONLY);

        assertEquals(1, report.errors().size());
        assertEquals("系统标识", report.errors().getFirst().column());
        assertTrue(report.errors().getFirst().message().contains("修改导入要求每行都带系统标识"));
    }

    @Test
    void detect_updateModeRejectsUnknownUuidsInsteadOfCreating() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.findById(any(UUID.class))).thenReturn(Optional.empty());
        GoodsImportService service = service(goods, null, null);

        GoodsImportReport report = service.detect(workbook("", "修改货品", "成品", UUID.randomUUID().toString(), null),
                java.util.Map.of(), java.util.Set.of(), java.util.Map.of(), GoodsImportMode.UPDATE_ONLY);

        assertEquals(1, report.errors().size());
        assertTrue(report.errors().getFirst().message().contains("未匹配到在库货品"));
        assertEquals(0, report.addedRows());
    }

    @Test
    void detect_updateModeRejectsSoftDeletedUuidsInsteadOfRestoring() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        UUID deletedId = UUID.randomUUID();
        var deleted = liveGoods(deletedId, "208035801", "已删货品");
        deleted.setDeleted(true);
        when(goods.findById(deletedId)).thenReturn(Optional.of(deleted));
        GoodsImportService service = service(goods, null, null);

        GoodsImportReport report = service.detect(workbook("208035801", "已删货品", "成品", deletedId.toString(), null),
                java.util.Map.of(), java.util.Set.of(), java.util.Map.of(), GoodsImportMode.UPDATE_ONLY);

        assertEquals(1, report.errors().size());
        assertTrue(report.errors().getFirst().message().contains("修改导入不能恢复"));
        assertEquals(0, report.restorableRows());
    }

    @Test
    void detect_updateModeMatchesLiveUuidsLikeMixedImport() throws Exception {
        login("goods:edit");
        MaterialCategory category = category();
        GoodsRepository goods = mock(GoodsRepository.class);
        UUID liveId = UUID.randomUUID();
        var existing = liveGoods(liveId, "208035801", "一致货品");
        existing.setCategory(category);
        when(goods.findById(liveId)).thenReturn(Optional.of(existing));
        var access = mock(com.uten.imp.application.port.GoodsMasterWriteAccessPort.class);
        GoodsImportService service = service(goods, null, null, category);
        ReflectionTestUtils.setField(service, "writeAccess", access);

        GoodsImportReport report = service.detect(workbook("208035801", "一致货品", "成品", liveId.toString(), null),
                java.util.Map.of(), java.util.Set.of(), java.util.Map.of(), GoodsImportMode.UPDATE_ONLY);

        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(1, report.unchangedRows());
        assertEquals(0, report.addedRows());
    }

    @Test
    void commit_rejectsWhenTheModeDiffersFromTheDetectedPlan() throws Exception {
        GoodsImportService service = service(mock(GoodsRepository.class), null, null);

        byte[] xlsx = workbook("", "新建货品", "成品", null, null);
        GoodsImportReport report = service.detect(xlsx, java.util.Map.of(), java.util.Set.of(), java.util.Map.of(),
                GoodsImportMode.CREATE_ONLY);
        assertNotNull(report.planId());

        ApiException rejected = assertThrows(ApiException.class,
                () -> service.commit(report.planId(), xlsx, "新建清单.xlsx"));
        assertTrue(rejected.getMessage().contains("导入模式与检测时不一致"));
    }

    // ---------- 组装信息ID ----------

    @Test
    void detect_rejectsAMalformedBomRef() throws Exception {
        GoodsImportService service = service(mock(GoodsRepository.class), null, null);

        GoodsImportReport report = service.detect(workbook("", "新建货品", "成品", null, "NOT-A-REF"));

        assertEquals(1, report.errors().size());
        assertEquals("组装信息ID", report.errors().getFirst().column());
        assertTrue(report.errors().getFirst().message().contains("格式不正确"));
    }

    @Test
    void detect_rejectsABomRefPointingAtAMissingGoods() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.findByCodeAndDeletedFalse("NOPE999")).thenReturn(Optional.empty());
        GoodsImportService service = service(goods, null, null);

        GoodsImportReport report = service.detect(workbook("", "新建货品", "成品", null, "NOPE999-BOM"));

        assertEquals(1, report.errors().size());
        assertTrue(report.errors().getFirst().message().contains("不存在或已删除"));
    }

    @Test
    void detect_rejectsABomRefWhenTheBomCreateAuthorityIsMissing() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        UUID sourceId = UUID.randomUUID();
        when(goods.findByCodeAndDeletedFalse("SRC001")).thenReturn(
                Optional.of(liveGoods(sourceId, "SRC001", "源货品")));
        GoodsImportService service = service(goods, null, null);

        GoodsImportReport report = service.detect(workbook("", "新建货品", "成品", null, "SRC001-BOM"));

        assertEquals(1, report.errors().size());
        assertTrue(report.errors().getFirst().message().contains("goods:bom:create"),
                () -> report.errors().toString());
    }

    @Test
    void detect_rejectsABomRefWhoseSourceHasNoOperationalRows() throws Exception {
        login("goods:bom:create");
        GoodsRepository goods = mock(GoodsRepository.class);
        UUID sourceId = UUID.randomUUID();
        when(goods.findByCodeAndDeletedFalse("SRC001")).thenReturn(
                Optional.of(liveGoods(sourceId, "SRC001", "源货品")));
        GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(sourceId)).thenReturn(List.of());
        GoodsImportService service = service(goods, null, bomRepo);

        GoodsImportReport report = service.detect(workbook("", "新建货品", "成品", null, "SRC001-BOM"));

        assertEquals(1, report.errors().size());
        assertTrue(report.errors().getFirst().message().contains("没有可复制的组装信息"));
    }

    @Test
    void detect_rejectsABomRefWhoseSourceContainsADisabledComponent() throws Exception {
        login("goods:bom:create");
        GoodsRepository goods = mock(GoodsRepository.class);
        UUID sourceId = UUID.randomUUID();
        Goods source = liveGoods(sourceId, "SRC001", "源货品");
        when(goods.findByCodeAndDeletedFalse("SRC001")).thenReturn(Optional.of(source));
        var component = liveGoods(UUID.randomUUID(), "CMP001", "停用组件");
        component.setStatus("禁用");
        GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(sourceId))
                .thenReturn(List.of(bomRow(source, component, "2")));
        GoodsImportService service = service(goods, null, bomRepo);

        GoodsImportReport report = service.detect(workbook("", "新建货品", "成品", null, "SRC001-BOM"));

        assertEquals(1, report.errors().size());
        assertTrue(report.errors().getFirst().message().contains("已停用组件"));
    }

    @Test
    void commit_appendsTheCopiedBomToANewlyCreatedGoods() throws Exception {
        login("goods:bom:create", "goods:edit");
        UUID sourceId = UUID.randomUUID();
        Goods source = liveGoods(sourceId, "SRC001", "源货品");
        var component = liveGoods(UUID.randomUUID(), "CMP001", "组件货品");
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.findByCodeAndDeletedFalse("SRC001")).thenReturn(Optional.of(source));
        GoodsService goodsService = mock(GoodsService.class);
        UUID createdId = UUID.randomUUID();
        when(goodsService.saveImported(any())).thenReturn(createdId);
        GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
        GoodsBomItem row = bomRow(source, component, "3");
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(sourceId)).thenReturn(List.of(row));
        GoodsBomPasteService paste = mock(GoodsBomPasteService.class);
        GoodsImportService service = service(goods, goodsService, bomRepo);
        ReflectionTestUtils.setField(service, "bomPaste", paste);

        byte[] xlsx = workbook("", "复制货品", "成品", null, "SRC001-BOM");
        GoodsImportReport report = service.detect(xlsx, java.util.Map.of(), java.util.Set.of(), java.util.Map.of(),
                GoodsImportMode.CREATE_ONLY);
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        service.commit(report.planId(), xlsx, "复制清单.xlsx", java.util.Set.of(), java.util.Map.of(),
                java.util.Set.of(), java.util.Map.of(), GoodsImportMode.CREATE_ONLY);

        ArgumentCaptor<BomPasteRequest> captor = ArgumentCaptor.forClass(BomPasteRequest.class);
        verify(paste).paste(captor.capture());
        BomPasteRequest request = captor.getValue();
        assertEquals(BomPasteRequest.Mode.APPEND, request.mode());
        assertEquals(createdId, request.targets().getFirst().goodsId());
        assertEquals(1, request.items().size());
        assertEquals(component.getId(), request.items().getFirst().getComponentGoodsId());
        assertEquals(0, new BigDecimal("3").compareTo(request.items().getFirst().getQty()));
        assertEquals(row.getId(), request.items().getFirst().getCopiedFromBomItemId());
    }

    @Test
    void commit_replacesTheBomOnAMatchedRowWithoutFieldChanges() throws Exception {
        login("goods:bom:create", "goods:bom:delete", "goods:edit");
        MaterialCategory category = category();
        UUID liveId = UUID.randomUUID();
        Goods existing = liveGoods(liveId, "208035801", "一致货品");
        existing.setCategory(category);
        UUID sourceId = UUID.randomUUID();
        Goods source = liveGoods(sourceId, "SRC001", "源货品");
        var component = liveGoods(UUID.randomUUID(), "CMP001", "组件货品");
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.findById(liveId)).thenReturn(Optional.of(existing));
        when(goods.findByCodeAndDeletedFalse("SRC001")).thenReturn(Optional.of(source));
        GoodsService goodsService = mock(GoodsService.class);
        GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
        when(bomRepo.findGoodsWithOperationalRows(any())).thenReturn(List.of(liveId));
        GoodsBomItem row = bomRow(source, component, "1");
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(sourceId)).thenReturn(List.of(row));
        UUID existingRowId = UUID.randomUUID();
        when(bomRepo.findOperationalEdges(any())).thenReturn(
                List.<Object[]>of(new Object[]{existingRowId, liveId, component.getId(), 1}));
        GoodsBomPasteService paste = mock(GoodsBomPasteService.class);
        GoodsImportService service = service(goods, goodsService, bomRepo, category);
        ReflectionTestUtils.setField(service, "writeAccess",
                mock(com.uten.imp.application.port.GoodsMasterWriteAccessPort.class));
        ReflectionTestUtils.setField(service, "bomPaste", paste);

        byte[] xlsx = workbook("208035801", "一致货品", "成品", liveId.toString(), "SRC001-BOM");
        GoodsImportReport report = service.detect(xlsx);
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        service.commit(report.planId(), xlsx, "替换组装.xlsx");

        ArgumentCaptor<BomPasteRequest> captor = ArgumentCaptor.forClass(BomPasteRequest.class);
        verify(paste).paste(captor.capture());
        BomPasteRequest request = captor.getValue();
        assertEquals(BomPasteRequest.Mode.REPLACE, request.mode());
        assertEquals(liveId, request.targets().getFirst().goodsId());
        assertEquals(List.of(existingRowId), request.targets().getFirst().expectedItemIds());
        verify(goodsService, org.mockito.Mockito.never()).updateImported(any(UUID.class), any());
    }

    @Test
    void detect_treatsASelfBomRefOnAMatchedRowAsANoOp() throws Exception {
        login("goods:edit");
        MaterialCategory category = category();
        UUID liveId = UUID.randomUUID();
        Goods existing = liveGoods(liveId, "208035801", "一致货品");
        existing.setCategory(category);
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.findById(liveId)).thenReturn(Optional.of(existing));
        when(goods.findByCodeAndDeletedFalse("208035801")).thenReturn(Optional.of(existing));
        GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
        when(bomRepo.findGoodsWithOperationalRows(any())).thenReturn(List.of(liveId));
        GoodsImportService service = service(goods, null, bomRepo, category);
        ReflectionTestUtils.setField(service, "writeAccess",
                mock(com.uten.imp.application.port.GoodsMasterWriteAccessPort.class));

        GoodsImportReport report = service.detect(workbook("208035801", "一致货品", "成品", liveId.toString(),
                "208035801-BOM"));

        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(1, report.unchangedRows());
        verify(bomRepo, org.mockito.Mockito.never())
                .findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(any(UUID.class));
    }

    // ---------- 夹具 ----------

    private static void login(String... authorities) {
        org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
                new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(
                        "goods-importer", "unused",
                        java.util.Arrays.stream(authorities)
                                .map(org.springframework.security.core.authority.SimpleGrantedAuthority::new)
                                .toList()));
    }

    private static Goods liveGoods(UUID id, String code, String name) {
        var existing = new Goods();
        existing.setId(id);
        existing.setCode(code);
        existing.setName(name);
        existing.setStatus("使用");
        return existing;
    }

    private static GoodsBomItem bomRow(Goods source, Goods component, String qty) {
        var row = new GoodsBomItem();
        row.setId(UUID.randomUUID());
        row.setGoods(source);
        row.setComponent(component);
        row.setQty(new BigDecimal(qty));
        return row;
    }

    private static MaterialCategory category() {
        var existingCategory = new MaterialCategory();
        existingCategory.setId(UUID.randomUUID());
        existingCategory.setName("成品");
        existingCategory.setCode("MODE-CAT");
        return existingCategory;
    }

    private static GoodsImportService service(GoodsRepository goods, GoodsService goodsService,
                                              GoodsBomItemRepository bomRepo) {
        return service(goods, goodsService, bomRepo, category());
    }

    private static GoodsImportService service(GoodsRepository goods, GoodsService goodsService,
                                              GoodsBomItemRepository bomRepo, MaterialCategory existingCategory) {
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc())
                .thenReturn(List.of(existingCategory));
        ColorRepository colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        UnitRepository units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        jakarta.persistence.EntityManager em = mock(jakarta.persistence.EntityManager.class);
        var nativeQuery = mock(jakarta.persistence.Query.class);
        when(nativeQuery.setParameter(anyString(), any())).thenReturn(nativeQuery);
        when(em.createNativeQuery(anyString())).thenReturn(nativeQuery);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        GoodsImportService service = new GoodsImportService(
                goodsService == null ? mock(GoodsService.class) : goodsService, goods, null, categories,
                null, colors, null, units, em, currentUser, null);
        if (bomRepo != null) ReflectionTestUtils.setField(service, "bomRepo", bomRepo);
        MasterObjectAccess access = mock(MasterObjectAccess.class);
        when(access.visibleGoodsOwner()).thenReturn(owner -> true);
        ReflectionTestUtils.setField(service, "bomAccess", access);
        return service;
    }

    private static byte[] workbook(String code, String name, String category, String goodsId, String bomRef)
            throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("编号");
            header.createCell(1).setCellValue("名称");
            header.createCell(2).setCellValue("类别");
            header.createCell(3).setCellValue("系统标识");
            header.createCell(4).setCellValue("组装信息ID");
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue(code);
            row.createCell(1).setCellValue(name);
            row.createCell(2).setCellValue(category);
            if (goodsId != null) row.createCell(3).setCellValue(goodsId);
            if (bomRef != null) row.createCell(4).setCellValue(bomRef);
            workbook.write(output);
            return output.toByteArray();
        }
    }
}
