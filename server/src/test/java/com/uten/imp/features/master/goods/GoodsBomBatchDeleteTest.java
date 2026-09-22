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
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Optional;
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
            events);

    private final Validator validator =
            Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void batchDeleteRemovesEveryCheckedRowAndLeavesTheRestAlone() {
        Goods parent = goods("P-1");
        GoodsBomItem first = bomRow(parent, goods("C-1"));
        GoodsBomItem second = bomRow(parent, goods("C-2"));
        GoodsBomItem keeper = bomRow(parent, goods("C-3"));
        stubRow(first);
        stubRow(second);
        stubRow(keeper);
        // 删完之后仓库里只剩没勾的那行，recalcSourceE 按这个现状重算。
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of(keeper));

        int deleted = service.deleteAll(
                parent.getId(), List.of(first.getId(), second.getId()));

        assertEquals(2, deleted);
        assertTrue(first.isDeleted());
        assertTrue(second.isDeleted());
        assertFalse(keeper.isDeleted());
        verify(bomRepo).save(first);
        verify(bomRepo).save(second);
        verify(bomRepo, never()).save(keeper);
        verify(references).requireVisibleGoods(parent.getId());
    }

    @Test
    void recalculationAndBomUpdatedEventFireOncePerBatchNotPerRow() {
        Goods parent = goods("P-1");
        GoodsBomItem first = bomRow(parent, goods("C-1"));
        GoodsBomItem second = bomRow(parent, goods("C-2"));
        stubRow(first);
        stubRow(second);
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
        stubRow(mine);
        stubRow(foreign);

        // 合法 id 排在前面：若实现边校验边落库，mine 早就被删了，这里就抓不到。
        ApiException error = assertThrows(ApiException.class,
                () -> service.deleteAll(parent.getId(), List.of(mine.getId(), foreign.getId())));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        assertFalse(mine.isDeleted());
        assertFalse(foreign.isDeleted());
        verify(bomRepo, never()).save(any());
        verify(goodsRepo, never()).save(any());
        verifyNoInteractions(events);
    }

    @Test
    void repeatedIdsAreDeletedAndCountedOnce() {
        Goods parent = goods("P-1");
        GoodsBomItem row = bomRow(parent, goods("C-1"));
        stubRow(row);
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of());

        int deleted = service.deleteAll(
                parent.getId(), List.of(row.getId(), row.getId(), row.getId()));

        assertEquals(1, deleted);
        verify(bomRepo, times(1)).save(row);
    }

    @Test
    void alreadyDeletedRowIsTreatedAsMissingSoRetriesDoNotSilentlySucceed() {
        Goods parent = goods("P-1");
        GoodsBomItem gone = bomRow(parent, goods("C-1"));
        gone.setDeleted(true);
        stubRow(gone);

        ApiException error = assertThrows(ApiException.class,
                () -> service.deleteAll(parent.getId(), List.of(gone.getId())));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        verify(bomRepo, never()).save(any());
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
                Collections.nCopies(201, UUID.randomUUID()));
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

    private void stubRow(GoodsBomItem row) {
        when(bomRepo.findById(row.getId())).thenReturn(Optional.of(row));
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
}
