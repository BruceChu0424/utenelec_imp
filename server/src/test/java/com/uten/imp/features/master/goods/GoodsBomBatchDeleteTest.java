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
import com.uten.imp.features.master.goods.dto.BomBatchDeleteRequest;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
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
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 组装信息批量删除(POST /api/master/goods/{id}/bom/batch-delete)。
 *
 * <p>盯住三件事：勾谁删谁、一条不合法整批不动手(越权与原子性是同一个闸)、重复勾选不重复计数。
 */
class GoodsBomBatchDeleteTest {

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

    @Test
    void batchDeleteRemovesEveryCheckedRowAndLeavesTheRestAlone() {
        Goods parent = goods("P-1");
        GoodsBomItem first = bomRow(parent, goods("C-1"));
        GoodsBomItem second = bomRow(parent, goods("C-2"));
        GoodsBomItem keeper = bomRow(parent, goods("C-3"));
        stubRows(first, second, keeper);
        // 删完之后仓库里只剩没勾的那行，recalcSourceE 按这个现状重算。
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of(keeper));

        int deleted = service.deleteAll(
                parent.getId(), List.of(first.getId(), second.getId()));

        assertEquals(2, deleted);
        assertTrue(first.isDeleted());
        assertTrue(second.isDeleted());
        assertFalse(keeper.isDeleted());
        verify(bomRepo, times(1)).softDeleteLive(Set.of(first.getId(), second.getId()));
        verify(references).requireVisibleGoods(parent.getId());
    }

    /** 语句数与勾选条数无关：一次取行 + 一条 UPDATE，不逐行 findById/save(ADR-111 评审修复)。 */
    @Test
    void rowsAreLoadedAndDeletedSetWiseNotOneByOne() {
        Goods parent = goods("P-1");
        List<GoodsBomItem> rows = new java.util.ArrayList<>();
        for (int i = 0; i < 50; i++) rows.add(bomRow(parent, goods("C-" + i)));
        stubRows(rows.toArray(GoodsBomItem[]::new));
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId())).thenReturn(List.of());

        int deleted = service.deleteAll(parent.getId(), rows.stream().map(GoodsBomItem::getId).toList());

        assertEquals(50, deleted);
        verify(bomRepo, times(1)).findLiveItemParents(any());
        verify(bomRepo, times(1)).softDeleteLive(any());
        verify(bomRepo, never()).findById(any());
        verify(bomRepo, never()).save(any());
    }

    @Test
    void recalculationAndBomUpdatedEventFireOncePerBatchNotPerRow() {
        Goods parent = goods("P-1");
        GoodsBomItem first = bomRow(parent, goods("C-1"));
        GoodsBomItem second = bomRow(parent, goods("C-2"));
        stubRows(first, second);
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of());

        service.deleteAll(parent.getId(), List.of(first.getId(), second.getId()));

        // 逐条删是每条一次重算 + 一次通知；批量删 20 行不能把计划部通知刷 20 遍。
        verify(goodsRepo, times(1)).save(parent);
        verify(events, times(1)).publish(
                "GOODS_BOM_UPDATED", "GOODS_BOM", parent.getId(), Map.of());
    }

    @Test
    void rowOfAnotherGoodsFailsTheWholeBatchWithoutDeletingAnything() {
        Goods parent = goods("P-1");
        Goods otherParent = goods("P-2");
        GoodsBomItem mine = bomRow(parent, goods("C-1"));
        GoodsBomItem foreign = bomRow(otherParent, goods("C-9"));
        stubRows(mine, foreign);

        // 合法 id 排在前面：若实现边校验边落库，mine 早就被删了，这里就抓不到。
        ApiException error = assertThrows(ApiException.class,
                () -> service.deleteAll(parent.getId(), List.of(mine.getId(), foreign.getId())));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        assertFalse(mine.isDeleted());
        assertFalse(foreign.isDeleted());
        verify(bomRepo, never()).softDeleteLive(any());
        verify(goodsRepo, never()).save(any());
        verifyNoInteractions(events);
    }

    /**
     * ADR-111：勾选可以横跨组装树的多层，一次请求、一个事务——嵌套行按它真正的父件软删、
     * 只重算那个父件，并核对它的可见性；不再由前端按父件分组逐组提交。
     */
    @Test
    void nestedRowInsideTheViewedTreeIsDeletedWithItsOwnParent() {
        Goods root = goods("P-1");
        Goods child = goods("C-1");
        GoodsBomItem nested = bomRow(child, goods("X-1"));
        stubRows(nested);
        when(bomRepo.findOperationalEdges(any())).thenReturn(Collections.singletonList(
                new Object[]{UUID.randomUUID(), root.getId(), child.getId(), 1}));
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(child.getId()))
                .thenReturn(List.of());

        int deleted = service.deleteAll(root.getId(), List.of(nested.getId()));

        assertEquals(1, deleted);
        assertTrue(nested.isDeleted());
        verify(references).requireVisibleGoods(root.getId());
        verify(references).requireVisibleGoods(child.getId());
        verify(goodsRepo, times(1)).save(child);
        verify(goodsRepo, never()).save(root);
        verify(events, times(1)).publish("GOODS_BOM_UPDATED", "GOODS_BOM", child.getId(), Map.of());
    }

    @Test
    void repeatedIdsAreDeletedAndCountedOnce() {
        Goods parent = goods("P-1");
        GoodsBomItem row = bomRow(parent, goods("C-1"));
        stubRows(row);
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of());

        int deleted = service.deleteAll(
                parent.getId(), List.of(row.getId(), row.getId(), row.getId()));

        assertEquals(1, deleted);
        verify(bomRepo, times(1)).softDeleteLive(Set.of(row.getId()));
    }

    @Test
    void alreadyDeletedRowIsTreatedAsMissingSoRetriesDoNotSilentlySucceed() {
        Goods parent = goods("P-1");
        GoodsBomItem gone = bomRow(parent, goods("C-1"));
        gone.setDeleted(true);
        stubRows(gone);

        ApiException error = assertThrows(ApiException.class,
                () -> service.deleteAll(parent.getId(), List.of(gone.getId())));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        verify(bomRepo, never()).softDeleteLive(any());
    }

    /** 读完到 UPDATE 之间别人删掉了其中一行：实际删掉的条数对不上，整批 404 回滚。 */
    @Test
    void rowDeletedConcurrentlyBetweenReadAndUpdateFailsTheWholeBatch() {
        Goods parent = goods("P-1");
        GoodsBomItem first = bomRow(parent, goods("C-1"));
        GoodsBomItem second = bomRow(parent, goods("C-2"));
        stubRows(first, second);
        org.mockito.Mockito.doReturn(1).when(bomRepo).softDeleteLive(any());

        ApiException error = assertThrows(ApiException.class,
                () -> service.deleteAll(parent.getId(), List.of(first.getId(), second.getId())));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        verifyNoInteractions(events);
    }

    @Test
    void emptyAndOversizedItemIdsAreRejectedByBeanValidation() {
        BomBatchDeleteRequest empty = request(List.of());
        assertTrue(validator.validate(empty).stream()
                .anyMatch(v -> v.getPropertyPath().toString().equals("itemIds")
                        && v.getConstraintDescriptor().getAnnotation() instanceof NotEmpty));

        BomBatchDeleteRequest missing = request(null);
        assertFalse(validator.validate(missing).isEmpty());

        BomBatchDeleteRequest oversized = request(
                Collections.nCopies(501, UUID.randomUUID()));
        assertTrue(validator.validate(oversized).stream()
                .anyMatch(v -> v.getPropertyPath().toString().equals("itemIds")
                        && v.getConstraintDescriptor().getAnnotation() instanceof Size));

        assertTrue(validator.validate(request(List.of(UUID.randomUUID()))).isEmpty());
    }

    @Test
    void controllerRejectsEmptySelectionBeforeReachingTheService() throws Exception {
        GoodsBomService serviceMock = mock(GoodsBomService.class);
        MockMvc mvc = MockMvcBuilders.standaloneSetup(new GoodsBomController(
                        serviceMock,
                        mock(XlsxExportService.class),
                        mock(WorkbookDownloadService.class),
                        mock(AuditService.class),
                        mock(SecurityContextCurrentUser.class)))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        mvc.perform(post("/api/master/goods/{id}/bom/batch-delete", UUID.randomUUID())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"itemIds\":[]}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));
        verifyNoInteractions(serviceMock);
    }

    @Test
    void controllerReturnsDeletedCountUnderTheAgreedJsonKey() throws Exception {
        GoodsBomService serviceMock = mock(GoodsBomService.class);
        UUID goodsId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        when(serviceMock.deleteAll(eq(goodsId), any())).thenReturn(2);
        MockMvc mvc = MockMvcBuilders.standaloneSetup(new GoodsBomController(
                        serviceMock,
                        mock(XlsxExportService.class),
                        mock(WorkbookDownloadService.class),
                        mock(AuditService.class),
                        mock(SecurityContextCurrentUser.class)))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        mvc.perform(post("/api/master/goods/{id}/bom/batch-delete", goodsId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"itemIds\":[\"" + itemId + "\"]}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.deleted").value(2));
    }

    /** 仓库替身：按 id 取仍有效的 [行, 父件]、一条 UPDATE 软删并返回实际删掉的条数。 */
    private void stubRows(GoodsBomItem... rows) {
        Map<UUID, GoodsBomItem> byId = new java.util.HashMap<>();
        Map<UUID, Goods> parents = new java.util.HashMap<>();
        for (GoodsBomItem row : rows) {
            byId.put(row.getId(), row);
            parents.put(row.getGoods().getId(), row.getGoods());
        }
        when(bomRepo.findLiveItemParents(any())).thenAnswer(call -> {
            Collection<UUID> ids = call.getArgument(0);
            List<Object[]> out = new java.util.ArrayList<>();
            for (UUID id : ids) {
                GoodsBomItem row = byId.get(id);
                if (row != null && !row.isDeleted()) out.add(new Object[]{id, row.getGoods().getId()});
            }
            return out;
        });
        when(bomRepo.softDeleteLive(any())).thenAnswer(call -> {
            Collection<UUID> ids = call.getArgument(0);
            int count = 0;
            for (UUID id : ids) {
                GoodsBomItem row = byId.get(id);
                if (row != null && !row.isDeleted()) {
                    row.setDeleted(true);
                    count++;
                }
            }
            return count;
        });
        when(goodsRepo.findAllById(any())).thenAnswer(call -> {
            Iterable<UUID> ids = call.getArgument(0);
            List<Goods> out = new java.util.ArrayList<>();
            for (UUID id : ids) {
                if (parents.containsKey(id)) out.add(parents.get(id));
            }
            return out;
        });
    }

    private static BomBatchDeleteRequest request(List<UUID> itemIds) {
        BomBatchDeleteRequest request = new BomBatchDeleteRequest();
        request.setItemIds(itemIds);
        return request;
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

    /** 组件可见性替身(ADR-111：列表按归属人一次判定)：默认全部可见。 */
    private static com.uten.imp.features.master.lifecycle.MasterObjectAccess allVisible() {
        com.uten.imp.features.master.lifecycle.MasterObjectAccess access = org.mockito.Mockito.mock(com.uten.imp.features.master.lifecycle.MasterObjectAccess.class);
        org.mockito.Mockito.when(access.visibleGoodsOwner()).thenReturn(owner -> true);
        return access;
    }
}
