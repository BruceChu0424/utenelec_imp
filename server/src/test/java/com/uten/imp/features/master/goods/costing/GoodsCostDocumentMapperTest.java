package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.export.ExportDocumentProjectionService;
import com.uten.imp.common.export.ExportTableProjectionService;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.mock;

class GoodsCostDocumentMapperTest {
    @Test void frozenMaterialSelectionExportsEveryPathPastTheFormerFiveThousandBoundary() throws Exception {
        var mapper = new ObjectMapper().findAndRegisterModules();
        com.fasterxml.jackson.databind.node.ObjectNode root = mapper.valueToTree(snapshot());
        var calculation = root.withObject("/calculation");
        var template = calculation.path("lines").get(0).deepCopy();
        var lines = calculation.putArray("lines");
        var paths = new java.util.ArrayList<String>();
        for (int index=0; index<5001; index++) {
            var line = (com.fasterxml.jackson.databind.node.ObjectNode) template.deepCopy();
            String path="root/"+index;
            line.put("path",path);
            lines.add(line); paths.add(path);
        }
        var frozen = mapper.treeToValue(root, GoodsCostContracts.Snapshot.class);
        var document = GoodsCostDocumentMapper.map(frozen,"MATERIAL",paths,null);
        assertThat(document.sections().getFirst().rows()).hasSize(5001);
        assertThat(document.sections().getFirst().rows().getLast()).containsEntry("rowKey","root/5000");
        paths.add("root/missing");
        assertThatThrownBy(() -> GoodsCostDocumentMapper.map(frozen,"MATERIAL",paths,null)).hasMessageContaining("选中物料");
    }
    @Test void selectedSameNameFeesUseFrozenIdentityAndBothFilesKeepExactAmount() throws Exception {
        var mapper = new ObjectMapper().findAndRegisterModules();
        com.fasterxml.jackson.databind.node.ObjectNode root = mapper.valueToTree(snapshot());
        var fees = root.withObject("/calculation").putArray("fees");
        fees.addObject().put("key","same").put("targetPath","root/edge").put("name","同名费用")
                .put("type","FIXED_BATCH").put("category","PROCESS").put("source","MANUAL")
                .put("amount","1.111111111111111111111111");
        fees.addObject().put("key","same").put("targetPath","root/other").put("name","同名费用")
                .put("type","FIXED_BATCH").put("category","PROCESS").put("source","PRICE_COLUMN")
                .put("amount","2.123456789012345678901234");
        fees.addObject().put("key","global").putNull("targetPath").put("name","同名费用")
                .put("type","FIXED_BATCH").put("category","PROCESS").put("source","MANUAL").put("amount","99");
        var snapshot = mapper.treeToValue(root,GoodsCostContracts.Snapshot.class);
        var projection = new TableColumnProjection("master.goods.cost.fees","view_goods_cost",List.of(
                new TableColumnProjection.Column("name","伪造费用名称",180d,"text",null),
                new TableColumnProjection.Column("amount","伪造金额",240d,"number",null),
                new TableColumnProjection.Column("source","伪造来源",120d,"text",null)),
                List.of(Map.of("rowKey",GoodsCostDocumentMapper.feeRowKey("same","root/other"))));
        var service = new ExportDocumentProjectionService(new ExportTableProjectionService(mock(PlatformColumnService.class)));
        var document = service.project(GoodsCostDocumentMapper.map(snapshot,"FEES",null,null),projection,"工序与费用","view_goods_cost");
        assertThat(document.sections()).hasSize(1);
        var section = document.sections().getFirst();
        assertThat(section.rows()).hasSize(1);
        assertThat(section.rows().getFirst()).containsEntry("source","PRICE_COLUMN");
        assertThat((BigDecimal)section.rows().getFirst().get("amount")).isEqualByComparingTo("2.123456789012345678901234");
        assertThat(section.columns()).extracting(c->c.label()).containsExactly("费用名称","测算金额","来源");
        assertThat(section.columns()).noneMatch(c->c.key().equals("rowKey"));
        byte[] xlsx = new com.uten.imp.common.export.XlsxExportService().buildDocument(document);
        try(var book = new org.apache.poi.xssf.usermodel.XSSFWorkbook(new java.io.ByteArrayInputStream(xlsx))) {
            assertThat(java.util.stream.IntStream.range(0,book.getNumberOfSheets()).mapToObj(book::getSheetName).toList())
                    .containsExactlyInAnyOrder("说明","工序与费用");
            var values = new java.util.ArrayList<String>();
            for(var row:book.getSheet("工序与费用"))for(var cell:row)values.add(new org.apache.poi.ss.usermodel.DataFormatter().formatCellValue(cell));
            assertThat(values).contains("2.123456789012345678901234").doesNotContain("1.111111111111111111111111");
        }
        byte[] pdf = new com.uten.imp.common.export.TabularPdfExportService().build(document,null);
        try(var read = org.apache.pdfbox.Loader.loadPDF(pdf)) {
            String text = new org.apache.pdfbox.text.PDFTextStripper().getText(read).replaceAll("\\s+","");
            assertThat(text).contains("2.123456789012345678901234").doesNotContain("1.111111111111111111111111");
        }
        var unknown = new TableColumnProjection(projection.tableKey(),projection.scope(),projection.columns(),List.of(Map.of("rowKey","missing")));
        assertThatThrownBy(()->service.project(GoodsCostDocumentMapper.map(snapshot,"FEES",null,null),unknown,"工序与费用","view_goods_cost"))
                .hasMessageContaining("选中记录");
    }

    @Test void feeIdentityUsesTheSameUtf16LengthsAndKeepsNullPathsDistinct() throws Exception {
        var shared = new ObjectMapper().readTree(java.nio.file.Path.of("../contracts/table-output-cost-identities.json").toFile());
        for(var sample:shared.path("fees")) {
            String path=sample.path("targetPath").isNull()?null:sample.path("targetPath").textValue();
            assertThat(GoodsCostDocumentMapper.feeRowKey(sample.path("feeKey").textValue(),path)).isEqualTo(sample.path("rowKey").textValue());
        }
    }

    @Test void materialSelectionRetainsTheOriginalBomPathEvenWhenGoodsLabelsRepeat() throws Exception {
        var mapper=new ObjectMapper().findAndRegisterModules();
        com.fasterxml.jackson.databind.node.ObjectNode root=mapper.valueToTree(snapshot());
        var lines=(com.fasterxml.jackson.databind.node.ArrayNode)root.path("calculation").path("lines");
        var second=lines.get(0).deepCopy();
        ((com.fasterxml.jackson.databind.node.ObjectNode)second).put("path","root/other").put("amount","22.123456789012345678901234");
        lines.add(second);
        var snapshot=mapper.treeToValue(root,GoodsCostContracts.Snapshot.class);
        var projection=new TableColumnProjection("master.goods.cost.material","view_goods_cost",List.of(
                new TableColumnProjection.Column("goodsName","名称",180d,"text",null),
                new TableColumnProjection.Column("amount","金额",240d,"number",null)),List.of(Map.of("rowKey","root/other")));
        var service=new ExportDocumentProjectionService(new ExportTableProjectionService(mock(PlatformColumnService.class)));
        var document=service.project(GoodsCostDocumentMapper.map(snapshot,"MATERIAL",List.of("root/other"),null),projection,"选中物料","view_goods_cost");
        assertThat(document.sections()).hasSize(1);
        assertThat(document.sections().getFirst().rows()).hasSize(1);
        assertThat((BigDecimal)document.sections().getFirst().rows().getFirst().get("amount")).isEqualByComparingTo("22.123456789012345678901234");
    }
    @Test void frozenPricesQuantitiesAndAmountsAreDistinctAndClientLabelsDoNotBecomeAuthority() throws Exception {
        var snapshot = snapshot();
        var projection = new TableColumnProjection("cost", "view_goods_cost", List.of(
                new TableColumnProjection.Column("goodsName", "伪造标题", 180d, "text", null),
                new TableColumnProjection.Column("fee:finish", "伪造价格", 130d, "text", null),
                new TableColumnProjection.Column("feeQty:finish", "伪造数量", 130d, "text", null),
                new TableColumnProjection.Column("feeAmount:finish", "伪造金额", 130d, "text", null),
                new TableColumnProjection.Column("amount", "伪造合计", 130d, "text", null)));
        var document = GoodsCostDocumentMapper.map(snapshot, "ALL", null, projection);
        var table = document.sections().stream().filter(s -> s.name().equals("物料明细")).findFirst().orElseThrow();
        assertThat(table.columns()).extracting(c -> c.label()).containsExactly("货品名称", "表面处理单价或费率", "表面处理计价数量", "表面处理 · 测算金额", "测算金额");
        var row = table.rows().getFirst();
        assertThat((BigDecimal) row.get("fee:finish")).isEqualByComparingTo("0.05");
        assertThat((BigDecimal) row.get("feeQty:finish")).isEqualByComparingTo("2");
        assertThat((BigDecimal) row.get("feeAmount:finish")).isEqualByComparingTo("0.10");
        assertThat((BigDecimal) row.get("amount")).isEqualByComparingTo("1.10");
        assertThat((BigDecimal) row.get("materialAmount")).isEqualByComparingTo("1");
        assertThat(row.get("usageBasis")).isEqualTo("本单覆盖");
        assertThat(document.metadata()).anyMatch(value -> value.contains("不要再次叠加"));
    }

    @Test void partialDownloadDoesNotClaimToBeTheWholeCostSheetOrIncludeUnselectedFees() throws Exception {
        var partial = GoodsCostDocumentMapper.map(snapshot(), "ALL", List.of("root/edge"), null);
        assertThat(partial.title()).contains("部分明细");
        assertThat(partial.sections()).noneMatch(s -> s.name().equals("成本汇总"));
        assertThatThrownBy(() -> GoodsCostDocumentMapper.map(snapshot(), "ALL", List.of("other-product"), null))
                .hasMessageContaining("选中物料");
    }

    @Test void feeViewProjectionDoesNotRemoveMaterialColumnsFromWholeDocument() throws Exception {
        var projection = new TableColumnProjection("master.goods.cost.fees", "view_goods_cost", List.of(
                new TableColumnProjection.Column("name", "客户端名称", 160d, "text", null),
                new TableColumnProjection.Column("goodsName", "客户端物料", 160d, "text", null),
                new TableColumnProjection.Column("value", "客户端单价", 100d, "text", null)));
        var doc = GoodsCostDocumentMapper.map(snapshot(), "ALL", null, projection);
        var materials = doc.sections().stream().filter(s -> s.name().equals("物料明细")).findFirst().orElseThrow();
        var fees = doc.sections().stream().filter(s -> s.name().equals("工序与费用")).findFirst().orElseThrow();
        assertThat(materials.columns()).anyMatch(c -> c.key().equals("goodsCode"));
        assertThat(fees.columns()).extracting(c -> c.key()).containsExactly("name", "goodsName", "value");
    }
    @Test void realScreenPriceSourceKeyCanBeTheOnlyExportedColumnAndPrefersTheFrozenBillNumber() throws Exception {
        var projection=new TableColumnProjection("master.goods.cost.items","view_goods_cost",List.of(
                new TableColumnProjection.Column("priceSource","客户端伪标题",165d,"text",null)));
        var document=GoodsCostDocumentMapper.map(snapshotWithPrice("APPROVED_PURCHASE","PO-2026-009"),"MATERIAL",null,null);
        var service=new ExportDocumentProjectionService(new ExportTableProjectionService(mock(PlatformColumnService.class)));
        var projected=service.project(document,projection,"物料明细","view_goods_cost").sections().getFirst();
        assertThat(projected.columns()).extracting(c->c.key()).containsExactly("priceSource");
        assertThat(projected.columns().getFirst().label()).isEqualTo("价格来源");
        assertThat(projected.rows().getFirst().get("priceSource")).isEqualTo("PO-2026-009");
    }
    @Test void sourcesWithoutBillNumbersUseChineseLabelsFromTheFrozenSourceType() throws Exception {
        var labels=Map.of("MANUAL","本单覆盖","APPROVED_PURCHASE","已批准来源价格","APPROVED_SUBCONTRACT","已批准委外价格",
                "INVENTORY_REFERENCE","库存参考价格","CUSTOMER_SUPPLIED","客供料");
        for(var item:labels.entrySet()) {
            var document=GoodsCostDocumentMapper.map(snapshotWithPrice(item.getKey()," "),"MATERIAL",null,null);
            assertThat(document.sections().getFirst().rows().getFirst().get("priceSource")).isEqualTo(item.getValue());
        }
    }
    @Test void estimateLabelsFollowTheFrozenProductUnitAndDoNotImplyActualProductionAmounts() throws Exception {
        var mapper=new ObjectMapper().findAndRegisterModules();
        for(String unit:List.of("套","件","")) {
            com.fasterxml.jackson.databind.node.ObjectNode root=mapper.valueToTree(snapshot());
            ((com.fasterxml.jackson.databind.node.ObjectNode)root.path("calculation")).put("unitName",unit);
            var document=GoodsCostDocumentMapper.map(mapper.treeToValue(root,GoodsCostContracts.Snapshot.class),"ALL",null,null);
            assertThat(document.metadata()).anyMatch(value->value.startsWith("测算数量: ")).noneMatch(value->value.startsWith("批量: "));
            var materials=document.sections().stream().filter(section->section.name().equals("物料明细")).findFirst().orElseThrow();
            assertThat(materials.columns().stream().filter(column->column.key().equals("unitContribution")).findFirst().orElseThrow().label())
                    .isEqualTo(unit.isBlank()?"单位成本":"每"+unit+"成本");
            assertThat(materials.columns().stream().filter(column->column.key().equals("batchQty")).findFirst().orElseThrow().label()).isEqualTo("计价用量");
            for(String sectionName:List.of("成本汇总","物料明细","工序与费用"))
                assertThat(document.sections().stream().filter(section->section.name().equals(sectionName)).findFirst().orElseThrow()
                        .columns().stream().filter(column->column.key().equals("amount")).findFirst().orElseThrow().label()).isEqualTo("测算金额");
        }
    }
    private static GoodsCostContracts.Snapshot snapshotWithPrice(String sourceType,String number)throws Exception {
        var mapper=new ObjectMapper().findAndRegisterModules();
        com.fasterxml.jackson.databind.node.ObjectNode root=mapper.valueToTree(snapshot());
        var line=(com.fasterxml.jackson.databind.node.ObjectNode)root.path("calculation").path("lines").get(0);
        line.set("priceEvidence",mapper.createObjectNode().put("sourceType",sourceType).put("sourceNumber",number));
        return mapper.treeToValue(root,GoodsCostContracts.Snapshot.class);
    }

    private static GoodsCostContracts.Snapshot snapshot() throws Exception {
        return new ObjectMapper().findAndRegisterModules().readValue("""
                {"id":"00000000-0000-0000-0000-000000000001","sheetId":"00000000-0000-0000-0000-000000000002",
                 "sheetNo":"CB-TEST","sheetVersion":4,"kind":"DRAFT_EXPORT","contentDigest":"abc",
                 "input":{"priceColumns":[{"key":"finish","name":"表面处理","type":"PER_QUANTITY","category":"PROCESS","baseKeys":[]}],
                   "priceCells":[{"path":"root/edge","columnKey":"finish","value":"0.05","quantity":"2"}]},
                 "calculation":{"algorithmVersion":"test","calculatedAt":"2026-09-29T00:00:00Z",
                   "goodsCode":"PRODUCT","goodsName":"产品","unitName":"个","currencyName":"本币","batchQty":"1","exchangeRateToLocal":"1",
                   "lines":[{"id":"edge","path":"root/edge","goodsCode":"PART","goodsName":"物料","unitName":"个",
                     "designQty":"2","adoptedQty":"2","usageBasis":"MANUAL","batchQty":"2","unitPrice":"0.5",
                     "amount":"1.10","materialAmount":"1","feeAmount":"0.1","unitContribution":"1.1","included":true,
                     "valueState":"COMPLETE","route":"PURCHASE","extraCosts":{"finish":"0.10"}}],
                   "fees":[],"totals":{"material":"1","process":"0.1","management":"0","other":"0","knownTotal":"1.1","unitCost":"1.1","valueState":"COMPLETE"},
                   "issues":[],"sourceRevisions":{}}}
                """, GoodsCostContracts.Snapshot.class);
    }
}
