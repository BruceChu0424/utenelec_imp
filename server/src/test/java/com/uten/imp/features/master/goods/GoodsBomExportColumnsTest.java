package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 配件清单导出（2026-09-25 口径「表格显示啥导出啥」）：
 *
 * <p>导出列集与前端组装信息表格一致——需求阶段/缺料处理/单价/金额四列已从表格
 * 退役，导出同步不带；层级只用级联序号表达（1 / 2 / 2.1），不再加全角空格缩进、
 * └ 分支符或子层星号标记；计量方式/尾包按展示文字导出（尾包仅「按包装」有意义）。</p>
 */
class GoodsBomExportColumnsTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);

    private final GoodsBomService service = new GoodsBomService(
            goodsRepo, bomRepo, mock(ColorRepository.class), mock(UnitRepository.class),
            mock(TxSessionVars.class),
            mock(com.uten.imp.security.SecurityContextCurrentUser.class),
            mock(MasterReferenceValidationPort.class),
            mock(GoodsMasterRelationshipResolver.class),
            mock(com.uten.imp.application.port.BusinessEventPublisher.class),
            accessAllowingAll());

    private static com.uten.imp.features.master.lifecycle.MasterObjectAccess accessAllowingAll() {
        com.uten.imp.features.master.lifecycle.MasterObjectAccess access =
                mock(com.uten.imp.features.master.lifecycle.MasterObjectAccess.class);
        when(access.visibleGoodsOwner()).thenReturn(owner -> true);
        return access;
    }

    @Test
    void exportColumnsMirrorTheTableAndUsePlainCascadeSequence() {
        Goods root = goods("P-1", "面板");
        Goods shell = goods("K01", "外壳");
        Goods screw = goods("S01", "螺丝");
        Goods washer = goods("D01", "垫片");

        GoodsBomItem rowShell = bomRow(root, shell, "2");
        GoodsBomItem rowScrew = bomRow(root, screw, "4");
        rowScrew.setConsumptionBasis("PER_PACKAGE");
        rowScrew.setAllowPartialPackage(false);
        rowScrew.setBasisOutputQty(BigDecimal.TEN);
        GoodsBomItem rowWasher = bomRow(screw, washer, "1");

        when(goodsRepo.findById(root.getId())).thenReturn(Optional.of(root));
        when(goodsRepo.findById(screw.getId())).thenReturn(Optional.of(screw));
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(root.getId()))
                .thenReturn(List.of(rowShell, rowScrew));
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(screw.getId()))
                .thenReturn(List.of(rowWasher));
        when(bomRepo.findGoodsWithOperationalRows(anyCollection()))
                .thenReturn(List.of(screw.getId()));

        ExportPayload payload = service.exportPayload(root.getId());

        // 列集 = 组装信息表格列（四列退役后），共 13 列、顺序即表格顺序。
        assertEquals(
                List.of("序号", "物料编号", "物料名称", "型号", "规格", "单位", "颜色", "来源",
                        "计量方式", "基准产量", "尾包", "数量", "备注"),
                payload.columns().stream().map(c -> c.label()).collect(Collectors.toList()),
                () -> "导出列必须与表格列一致");

        // 整树平铺：外壳 / 螺丝 / 垫片(螺丝的下级)。
        assertEquals(3, payload.rows().size());
        Map<String, Map<String, Object>> bySeq = payload.rows().stream()
                .collect(Collectors.toMap(r -> String.valueOf(r.get("seq")), r -> r));

        // 级联序号直接是 1 / 2 / 2.1：不带缩进、不带 └ 分支符，编号不带 * 前缀。
        for (Map<String, Object> row : payload.rows()) {
            String seq = (String) row.get("seq");
            assertFalse(seq.contains("└"), () -> "序号不应再带分支符: " + seq);
            assertFalse(seq.startsWith("　"), () -> "序号不应再缩进: " + seq);
            String code = String.valueOf(row.get("code"));
            assertFalse(code.startsWith("*"), () -> "编号不应再带星号前缀: " + code);
        }
        assertEquals("K01", bySeq.get("1").get("code"));
        assertEquals("S01", bySeq.get("2").get("code"));
        assertEquals("D01", bySeq.get("2.1").get("code"));

        // 计量方式/尾包按展示文字：按每件→尾包 —；按包装(整包)→整包。
        assertEquals("按每件", bySeq.get("1").get("consumptionBasis"));
        assertEquals("—", bySeq.get("1").get("allowPartialPackage"));
        assertEquals("按包装", bySeq.get("2").get("consumptionBasis"));
        assertEquals("整包", bySeq.get("2").get("allowPartialPackage"));
        assertEquals(0, BigDecimal.TEN.compareTo(
                new BigDecimal(String.valueOf(bySeq.get("2").get("basisOutputQty")))));
    }

    private static GoodsBomItem bomRow(Goods parent, Goods component, String qty) {
        GoodsBomItem row = new GoodsBomItem();
        row.setGoods(parent);
        row.setComponent(component);
        row.setQty(new BigDecimal(qty));
        return row;
    }

    private static Goods goods(String code, String name) {
        Goods goods = new Goods();
        goods.setCode(code);
        goods.setName(name);
        goods.setSourceType("采购");
        return goods;
    }
}
