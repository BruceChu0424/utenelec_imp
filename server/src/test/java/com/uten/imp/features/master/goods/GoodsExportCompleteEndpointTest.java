package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.*;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.io.ByteArrayInputStream;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class GoodsExportCompleteEndpointTest {
    @Test void theReportedGoodsEndpointExportsAll1201RowsWithTheOriginalFiltersAndOldSetting500() throws Exception {
        var goods = mock(GoodsService.class);
        var limits = mock(ExportLimitPort.class);
        when(limits.exportMaxRows()).thenReturn(500);
        var columns = List.of(new ExportColumn("code","编号",ExportColumn.TEXT),
                new ExportColumn("goodsId","系统标识",ExportColumn.TEXT));
        UUID category = UUID.randomUUID();
        when(goods.export(any(GoodsQueryFilter.class),eq("code"),eq("desc"),eq(500))).thenAnswer(call -> {
            GoodsQueryFilter filter = call.getArgument(0);
            assertThat(filter.categoryId()).isEqualTo(category);
            assertThat(filter.keyword()).isEqualTo("原筛选");
            assertThat(filter.excludeStub()).isTrue();
            var sink = java.util.Objects.requireNonNull(ExportPageSink.current());
            for(int first=0; first<1201; first+=100) {
                var rows=IntStream.range(first,Math.min(1201,first+100)).mapToObj(index -> Map.<String,Object>of(
                        "code","GOOD-"+index,"goodsId",new UUID(1,index).toString())).toList();
                sink.accept(new ExportPayload(columns,rows,first+rows.size()));
            }
            return new ExportPayload(columns,List.of(),1201);
        });
        var controller = new GoodsController(goods,new XlsxExportService(),new WorkbookDownloadService(),
                mock(AuditService.class),mock(SecurityContextCurrentUser.class),mock(AuditDetailViewRecorder.class),limits);
        ReflectionTestUtils.setField(controller,"request",new MockHttpServletRequest());
        byte[] bytes;
        try(var operation=new LegacyExportBudget(1).open()) {
            bytes=MockMvcBuilders.standaloneSetup(controller).build().perform(post("/api/master/goods/export")
                    .param("categoryId",category.toString()).param("keyword","原筛选").param("excludeStub","true")
                    .param("sort","code").param("order","desc").contentType("application/json")
                    .content("{\"password\":\"\"}"))
                    .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray();
        }
        try(var workbook=WorkbookFactory.create(new ByteArrayInputStream(bytes))) {
            var sheet=workbook.getSheetAt(0);
            assertThat(sheet.getLastRowNum()).isEqualTo(1201);
            assertThat(sheet.getRow(1201).getCell(0).getStringCellValue()).isEqualTo("GOOD-1200");
            assertThat(sheet.getRow(1201).getCell(1).getStringCellValue()).isEqualTo(new UUID(1,1200).toString());
        }
        verify(goods,times(1)).export(any(GoodsQueryFilter.class),eq("code"),eq("desc"),eq(500));
    }
}
