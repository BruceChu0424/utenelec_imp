package com.uten.imp.features.master.goods;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportTableProjectionService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 2026-10-20 内部测试反馈的端到端回归：组装信息表点「导出组件」报
 * 「列不存在或不在可导出范围：treeIdentity」。修复后前端投影不再带树形身份列，
 * 但仍带 source/color 这类与导出列不同名的列——本测试用今天表格真实发送的键集
 * 打整个导出链（Controller 收口补列 → 共享投影校验/别名 → xlsx 落盘）。
 */
class GoodsBomExportEndpointTest {

    @Test
    void theExactProjectionTodayGoodsBomTableSendsExportsTheWholeRecipe() throws Exception {
        GoodsBomService service = mock(GoodsBomService.class);
        when(service.exportPayload(any(UUID.class))).thenReturn(new ExportPayload(GoodsBomService.EXPORT_COLUMNS,
                List.of(Map.of("seq", "1", "code", "K01", "name", "外壳",
                        "qty", new BigDecimal("2"), "sourceType", "采购", "colorName", "白")),
                1));
        var controller = new GoodsBomController(service, writer(), new WorkbookDownloadService(),
                mock(AuditService.class), mock(SecurityContextCurrentUser.class));

        byte[] downloaded = MockMvcBuilders.standaloneSetup(controller).build().perform(
                post("/api/master/goods/{id}/bom/export", UUID.randomUUID())
                        .contentType("application/json")
                        .content("""
                                {"columnProjection":{"tableKey":"features.basic_data.widgets.goods_bom_tab","columns":[
                                  {"key":"learned","label":"学习来源"},
                                  {"key":"code","label":"编号"},
                                  {"key":"model","label":"型号"},
                                  {"key":"spec","label":"规格"},
                                  {"key":"color","label":"颜色"},
                                  {"key":"source","label":"来源"},
                                  {"key":"consumptionBasis","label":"计量方式"},
                                  {"key":"basisOutputQty","label":"基准产量"},
                                  {"key":"allowPartialPackage","label":"尾包"},
                                  {"key":"qty","label":"设计使用数量"},
                                  {"key":"actualQty","label":"真实使用数量"},
                                  {"key":"summary","label":"备注"}]},"password":""}
                                """))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray();

        try (Workbook workbook = WorkbookFactory.create(new ByteArrayInputStream(downloaded))) {
            List<String> labels = new ArrayList<>();
            for (Cell cell : workbook.getSheetAt(0).getRow(0)) labels.add(cell.getStringCellValue());
            // code/qty 用户选了不重复补；缺失的 seq/name 按标准序补在最前；
            // color→colorName、source→sourceType 走别名；表头保留用户文字。
            assertEquals(List.of("序号", "物料名称", "学习来源", "编号", "型号", "规格", "颜色", "来源",
                    "计量方式", "基准产量", "尾包", "设计使用数量", "真实使用数量", "备注"), labels);
            assertEquals("1", workbook.getSheetAt(0).getRow(1).getCell(0).getStringCellValue());
            assertEquals("外壳", workbook.getSheetAt(0).getRow(1).getCell(1).getStringCellValue());
            assertEquals("K01", workbook.getSheetAt(0).getRow(1).getCell(3).getStringCellValue());
        }
    }

    private static XlsxExportService writer() {
        var service = new XlsxExportService();
        @SuppressWarnings("unchecked")
        ObjectProvider<ExportTableProjectionService> provider = mock(ObjectProvider.class);
        when(provider.getObject())
                .thenReturn(new ExportTableProjectionService(mock(PlatformColumnService.class)));
        ReflectionTestUtils.setField(service, "projections", provider);
        return service;
    }
}
