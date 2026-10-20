package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomMoveRequest;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 组装信息拖拽移动(PUT /api/master/goods/{id}/bom/move，2026-10-19)。
 *
 * <p>盯住五件事：同层重排的顺序号重编、跨层移动换父件、成环拒绝、目标层重复拒绝、
 * 整批原子（一条不合法一条都不动）。
 */
class GoodsBomMoveTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
    private final MasterReferenceValidationPort references = mock(MasterReferenceValidationPort.class);
    private final BusinessEventPublisher events = mock(BusinessEventPublisher.class);
    private final GoodsBomService service = new GoodsBomService(
            goodsRepo,
            bomRepo,
            mock(ColorRepository.class),
            mock(UnitRepository.class),
            mock(TxSessionVars.class),
            mock(SecurityContextCurrentUser.class),
            references,
            mock(GoodsMasterRelationshipResolver.class),
            events,
            allVisible());

    private final Validator validator =
            Validation.buildDefaultValidatorFactory().getValidator();

    /** 同层下移：拖到锚点行之后，整层 sort_order 按新顺序重编（0..n-1）。 */
    @Test
    void sameLevelMoveInsertsAfterAnchorAndRenumbersTheWholeLevel() {
        Goods root = goods("P-1");
        GoodsBomItem first = bomRow(root, goods("C-1"));
        GoodsBomItem second = bomRow(root, goods("C-2"));
        GoodsBomItem third = bomRow(root, goods("C-3"));
        first.setSortOrder(0);
        second.setSortOrder(1);
        third.setSortOrder(2);
        stub(root, new GoodsBomItem[]{first, second, third}, List.of(), Map.of());

        int moved = service.moveAll(root.getId(), List.of(
                move(first.getId(), root.getId(), second.getId(), true)));

        assertEquals(1, moved);
        assertSame(root, first.getGoods());
        assertSame(second, rootRows(root).get(0));
        assertSame(first, rootRows(root).get(1));
        assertSame(third, rootRows(root).get(2));
        assertEquals(0, second.getSortOrder());
        assertEquals(1, first.getSortOrder());
        assertEquals(2, third.getSortOrder());
        verify(goodsRepo, times(1)).save(root);
        verify(events, times(1)).publish("GOODS_BOM_UPDATED", "GOODS_BOM", root.getId(), Map.of());
    }

    /** 跨层移动：换 goods 引用到目标父件，追加到该层末尾。 */
    @Test
    void crossLevelMoveReparentsAndAppendsToTheTargetLevel() {
        Goods root = goods("P-1");
        Goods child = goods("C-1");
        GoodsBomItem nested = bomRow(child, goods("X-1"));
        GoodsBomItem moved = bomRow(root, goods("C-2"));
        stub(root, new GoodsBomItem[]{nested, moved},
                List.<Object[]>of(edge(root.getId(), child.getId())),
                Map.of(child.getId(), List.of(nested)));

        int count = service.moveAll(root.getId(), List.of(
                move(moved.getId(), child.getId(), null, false)));

        assertEquals(1, count);
        assertSame(child, moved.getGoods());
        // 目标层的清单里，被移行追加在末尾。
        List<GoodsBomItem> childRows = rowsByParent.get(child.getId());
        assertSame(nested, childRows.get(0));
        assertSame(moved, childRows.get(1));
        verify(references).requireVisibleGoods(child.getId());
    }

    /** 成环：目标父件在被移组件自己的子树里 → 拒绝，行不动。 */
    @Test
    void movingARowIntoItsOwnSubtreeIsRejected() {
        Goods root = goods("P-1");
        Goods component = goods("C-1");
        Goods deep = goods("X-1");
        GoodsBomItem row = bomRow(root, component);
        stub(root, new GoodsBomItem[]{row},
                List.<Object[]>of(edge(component.getId(), deep.getId())),
                Map.of());

        ApiException error = assertThrows(ApiException.class,
                () -> service.moveAll(root.getId(), List.of(
                        move(row.getId(), deep.getId(), null, false))));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertSame(root, row.getGoods());
        verifyNoInteractions(events);
    }

    /** 目标层重复：目标父件下已有同一组件 → 拒绝（部分唯一索引兜底前的友好报错）。 */
    @Test
    void movingIntoALevelThatAlreadyHasTheComponentIsRejected() {
        Goods root = goods("P-1");
        Goods child = goods("C-1");
        Goods component = goods("C-2");
        GoodsBomItem row = bomRow(root, component);
        GoodsBomItem existing = bomRow(child, component);
        stub(root, new GoodsBomItem[]{row, existing}, List.of(), Map.of());
        when(bomRepo.findByGoods_IdAndComponent_IdAndDeletedFalse(child.getId(), component.getId()))
                .thenReturn(java.util.Optional.of(existing));

        ApiException error = assertThrows(ApiException.class,
                () -> service.moveAll(root.getId(), List.of(
                        move(row.getId(), child.getId(), null, false))));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertSame(root, row.getGoods());
        verifyNoInteractions(events);
    }

    /** 整批原子：合法 move 排在前面、非法 move 排在后面，异常抛出后事件不发。 */
    @Test
    void oneInvalidMoveFailsTheWholeBatch() {
        Goods root = goods("P-1");
        Goods elsewhere = goods("OUTSIDE");
        GoodsBomItem first = bomRow(root, goods("C-1"));
        GoodsBomItem second = bomRow(root, goods("C-2"));
        stub(root, new GoodsBomItem[]{first, second}, List.of(), Map.of());

        ApiException error = assertThrows(ApiException.class,
                () -> service.moveAll(root.getId(), List.of(
                        move(first.getId(), root.getId(), second.getId(), true),
                        move(second.getId(), elsewhere.getId(), null, false))));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        verify(goodsRepo, never()).save(any());
        verifyNoInteractions(events);
    }

    /** 锚点行在目标层不存在 → 404（参照行被别人删掉的重试路径）。 */
    @Test
    void missingAnchorRowIsReportedAsNotFound() {
        Goods root = goods("P-1");
        GoodsBomItem row = bomRow(root, goods("C-1"));
        stub(root, new GoodsBomItem[]{row}, List.of(), Map.of());

        ApiException error = assertThrows(ApiException.class,
                () -> service.moveAll(root.getId(), List.of(
                        move(row.getId(), root.getId(), UUID.randomUUID(), false))));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
    }

    @Test
    void emptyAndOversizedMovesAreRejectedByBeanValidation() {
        BomMoveRequest empty = new BomMoveRequest();
        empty.setMoves(List.of());
        assertFalse(validator.validate(empty).isEmpty());

        BomMoveRequest oversized = new BomMoveRequest();
        List<BomMoveRequest.Move> moves = new ArrayList<>();
        for (int i = 0; i < 501; i++) moves.add(new BomMoveRequest.Move());
        oversized.setMoves(moves);
        assertTrue(validator.validate(oversized).stream()
                .anyMatch(v -> v.getPropertyPath().toString().equals("moves")));
    }

    @Test
    void controllerReturnsMovedCountUnderTheAgreedJsonKey() throws Exception {
        GoodsBomService serviceMock = mock(GoodsBomService.class);
        UUID goodsId = UUID.randomUUID();
        when(serviceMock.moveAll(eq(goodsId), any())).thenReturn(3);
        MockMvc mvc = MockMvcBuilders.standaloneSetup(new GoodsBomController(
                        serviceMock,
                        mock(XlsxExportService.class),
                        mock(WorkbookDownloadService.class),
                        mock(AuditService.class),
                        mock(SecurityContextCurrentUser.class)))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        UUID itemId = UUID.randomUUID();
        UUID parent = UUID.randomUUID();
        mvc.perform(put("/api/master/goods/{id}/bom/move", goodsId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"moves\":[{\"itemId\":\"" + itemId
                                + "\",\"targetParentGoodsId\":\"" + parent + "\"}]}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.moved").value(3));
    }

    // ===== 替身 =====

    private final Map<UUID, List<GoodsBomItem>> rowsByParent = new HashMap<>();
    private final Map<UUID, GoodsBomItem> rowsById = new HashMap<>();
    private final Map<UUID, Goods> goodsById = new HashMap<>();

    private List<GoodsBomItem> rootRows(Goods parent) {
        return rowsByParent.get(parent.getId());
    }

    /**
     * 仓库替身：按 id 取行、按父件取层清单（返回同一可变列表——重排发生在替身列表上，
     * 顺序断言才有意义）、操作边按请求的 frontier 过滤。
     */
    private void stub(Goods root, GoodsBomItem[] rows, List<Object[]> edges,
                      Map<UUID, List<GoodsBomItem>> extraLevels) {
        for (GoodsBomItem row : rows) {
            rowsById.put(row.getId(), row);
            goodsById.put(row.getGoods().getId(), row.getGoods());
            goodsById.put(row.getComponent().getId(), row.getComponent());
            rowsByParent.computeIfAbsent(row.getGoods().getId(), k -> new ArrayList<>()).add(row);
        }
        goodsById.put(root.getId(), root);
        for (Map.Entry<UUID, List<GoodsBomItem>> level : extraLevels.entrySet()) {
            rowsByParent.put(level.getKey(), new ArrayList<>(level.getValue()));
        }
        when(bomRepo.findAllById(any())).thenAnswer(call -> {
            Iterable<UUID> ids = call.getArgument(0);
            List<GoodsBomItem> out = new ArrayList<>();
            for (UUID id : ids) {
                GoodsBomItem row = rowsById.get(id);
                if (row != null) out.add(row);
            }
            return out;
        });
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(any()))
                .thenAnswer(call -> rowsByParent.get((UUID) call.getArgument(0)));
        when(bomRepo.findOperationalEdges(any())).thenAnswer(call -> {
            Iterable<UUID> frontier = call.getArgument(0);
            List<Object[]> out = new ArrayList<>();
            for (Object[] edge : edges) {
                for (UUID parent : frontier) {
                    if (edge[1].equals(parent)) {
                        out.add(edge);
                        break;
                    }
                }
            }
            return out;
        });
        when(goodsRepo.findAllById(any())).thenAnswer(call -> {
            Iterable<UUID> ids = call.getArgument(0);
            List<Goods> out = new ArrayList<>();
            for (UUID id : ids) {
                Goods goods = goodsById.get(id);
                if (goods != null) out.add(goods);
            }
            return out;
        });
    }

    private static Object[] edge(UUID parent, UUID component) {
        return new Object[]{UUID.randomUUID(), parent, component, 0};
    }

    private static BomMoveRequest.Move move(UUID itemId, UUID targetParent,
                                           UUID anchor, boolean afterAnchor) {
        BomMoveRequest.Move move = new BomMoveRequest.Move();
        move.setItemId(itemId);
        move.setTargetParentGoodsId(targetParent);
        move.setAnchorItemId(anchor);
        move.setAfterAnchor(afterAnchor);
        return move;
    }

    private static GoodsBomItem bomRow(Goods parent, Goods component) {
        GoodsBomItem row = new GoodsBomItem();
        row.setGoods(parent);
        row.setComponent(component);
        row.setQty(BigDecimal.ONE);
        return row;
    }

    private static Goods goods(String code) {
        Goods goods = new Goods();
        goods.setCode(code);
        goods.setName("真实货品 " + code);
        goods.setAutoCreated(false);
        return goods;
    }

    /** 组件可见性替身：默认全部可见。 */
    private static com.uten.imp.features.master.lifecycle.MasterObjectAccess allVisible() {
        com.uten.imp.features.master.lifecycle.MasterObjectAccess access =
                org.mockito.Mockito.mock(com.uten.imp.features.master.lifecycle.MasterObjectAccess.class);
        org.mockito.Mockito.when(access.visibleGoodsOwner()).thenReturn(owner -> true);
        return access;
    }
}
