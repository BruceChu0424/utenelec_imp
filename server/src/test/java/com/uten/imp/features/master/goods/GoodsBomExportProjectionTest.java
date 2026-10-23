package com.uten.imp.features.master.goods;

import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * 配件清单导出投影收口（2026-10-20「导出组件」报 treeIdentity 不在可导出范围）：
 * 前端树形身份列/已审列不进投影后，序号/物料编号/物料名称/设计使用数量（BOM 导入
 * 的最小回环表头 + 文件可读性底线）必须在服务端补齐、排最前。
 */
class GoodsBomExportProjectionTest {

    private static TableColumnProjection.Column col(String key, String label) {
        return new TableColumnProjection.Column(key, label, 120d, "text", null);
    }

    @Test
    void nullProjectionStaysNullSoBackendExportsItsDefaultColumnSet() {
        assertNull(GoodsBomExportProjection.forImportTemplate(null));
    }

    @Test
    void malformedProjectionPassesThroughToTheSharedValidator() {
        var empty = new TableColumnProjection("t", null, List.of());
        assertSame(empty, GoodsBomExportProjection.forImportTemplate(empty));
        var withNullColumn = new TableColumnProjection("t", null,
                new ArrayList<>(java.util.Arrays.<TableColumnProjection.Column>asList(col("qty", "数量"), null)));
        assertSame(withNullColumn, GoodsBomExportProjection.forImportTemplate(withNullColumn));
    }

    @Test
    void missingImportColumnsArePrependedInCanonicalOrder() {
        var projected = GoodsBomExportProjection.forImportTemplate(new TableColumnProjection(
                "features...goods_bom_tab", null, List.of(col("learned", "学习来源"))));
        assertEquals(List.of("seq", "code", "name", "qty", "learned", "componentGoodsId"),
                projected.columns().stream().map(TableColumnProjection.Column::key).toList());
        assertEquals(List.of("序号", "物料编号", "物料名称", "设计使用数量", "学习来源", "组件系统标识"),
                projected.columns().stream().map(TableColumnProjection.Column::label).toList());
    }

    @Test
    void partiallyPresentColumnsKeepUserLabelsAndOrder() {
        var projected = GoodsBomExportProjection.forImportTemplate(new TableColumnProjection(
                "t", null, List.of(col("learned", "来源分类"), col("code", "组件编号"))));
        // code 已在选列里：不重复补；缺失的 seq/name/qty 按标准序排最前。
        assertEquals(List.of("seq", "name", "qty", "learned", "code", "componentGoodsId"),
                projected.columns().stream().map(TableColumnProjection.Column::key).toList());
        assertEquals("组件编号", projected.columns().get(4).label());
        assertEquals("来源分类", projected.columns().get(3).label());
    }

    @Test
    void presentColumnsAreNeitherDuplicatedNorReordered() {
        var projected = GoodsBomExportProjection.forImportTemplate(new TableColumnProjection(
                "t", null, List.of(col("name", "品名"), col("qty", "数量"), col("seq", "序号"))));
        // 只有 code 缺失：补在最前，用户的三列原序原样跟在后面，不重复。
        assertEquals(List.of("code", "name", "qty", "seq", "componentGoodsId"),
                projected.columns().stream().map(TableColumnProjection.Column::key).toList());
        assertEquals("品名", projected.columns().get(1).label());
    }

    @Test
    void overflowingSelectionFailsInsteadOfSilentlyDroppingRequiredColumns() {
        List<TableColumnProjection.Column> many = new ArrayList<>();
        for (int i = 0; i < 160; i++) many.add(col("c" + i, "列" + i));
        var error = assertThrows(ApiException.class, () -> GoodsBomExportProjection.forImportTemplate(
                new TableColumnProjection("t", null, many)));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void systemIdentityHeaderCannotBeRenamedOutOfTheRoundTripContract() {
        var projected = GoodsBomExportProjection.forImportTemplate(new TableColumnProjection(
                "t", null, List.of(col("componentGoodsId", "自定义标识"), col("seq", "序号"))));
        assertEquals("组件系统标识", projected.columns().stream()
                .filter(column -> column.key().equals("componentGoodsId")).findFirst().orElseThrow().label());
    }
}
