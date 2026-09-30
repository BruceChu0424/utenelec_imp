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
        assertThat(table.columns()).extracting(c -> c.label()).containsExactly("货品名称", "表面处理单价或费率", "表面处理计价数量", "表面处理金额", "批次行成本");
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
