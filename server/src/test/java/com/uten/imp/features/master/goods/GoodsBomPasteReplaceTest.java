package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 粘贴替换按组件对齐(ADR-129)：目标里已有的同一组件原地覆盖(行 id 不变)，
 * 内容没变的行保留审核标记(系统学习边因此保留系统所有权)；清单外的组件才删、新组件才建。
 * 写入后的清单与报数(替换掉几个、写入几个)与「全删再全建」一致。
 */
class GoodsBomPasteReplaceTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
    private final EntityManager em = mock(EntityManager.class);
    private final Query softDelete = mock(Query.class);
    private final MasterObjectAccess access = mock(MasterObjectAccess.class);
    private final GoodsBomService bom = new GoodsBomService(
            goodsRepo, bomRepo, mock(ColorRepository.class), mock(UnitRepository.class),
            mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class),
            mock(MasterReferenceValidationPort.class), mock(GoodsMasterRelationshipResolver.class),
            mock(BusinessEventPublisher.class), access);
    private final GoodsBomPasteService paste = new GoodsBomPasteService(
            bom, goodsRepo, bomRepo, mock(MasterReferenceValidationPort.class), access,
            mock(TxSessionVars.class), em);

    private final Goods target = goods("P-1");
    private final Goods kept = goods("A-1");
    private final Goods dropped = goods("B-1");
    private final Goods added = goods("C-1");
    private GoodsBomItem keptRow;
    private GoodsBomItem droppedRow;

    @BeforeEach
    void setUp() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "tester", null, List.of(new SimpleGrantedAuthority("goods:bom:delete"))));
        keptRow = row(kept, "2", 1);
        keptRow.setAuditedAt(OffsetDateTime.now());
        keptRow.setAuditedBy(UUID.randomUUID());
        droppedRow = row(dropped, "1", 2);
        when(access.visibleGoodsOwner()).thenReturn(owner -> true);
        when(goodsRepo.findAllById(anyCollection())).thenReturn(List.of(target, kept, dropped, added));
        when(bomRepo.findOperationalEdges(anyCollection())).thenAnswer(invocation -> {
            Collection<?> parents = invocation.getArgument(0);
            if (!parents.contains(target.getId())) return List.of();
            List<Object[]> rows = new ArrayList<>();
            for (GoodsBomItem row : List.of(keptRow, droppedRow)) {
                rows.add(new Object[]{row.getId(), target.getId(), row.getComponent().getId(), row.getSortOrder()});
            }
            return rows;
        });
        when(bomRepo.findAllById(anyCollection())).thenReturn(List.of(keptRow));
        when(bomRepo.materialCost(any())).thenReturn(BigDecimal.ZERO);
        when(em.createNativeQuery(anyString())).thenReturn(softDelete);
        when(softDelete.setParameter(anyString(), any())).thenReturn(softDelete);
    }

    @AfterEach
    void clearAuthentication() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void unchangedComponentKeepsItsRowAndAuditMarkOnlyRealDifferencesAreWritten() {
        OffsetDateTime audited = keptRow.getAuditedAt();

        BomPasteResult result = paste.paste(request(line(kept, "2"), line(added, "3")));

        // 同一组件：原行原地保留，内容没变审核标记不丢，排序按粘贴顺序。
        assertEquals(audited, keptRow.getAuditedAt());
        assertEquals(1, keptRow.getSortOrder());
        // 清单外的组件软删(一条 UPDATE)，只删它。
        ArgumentCaptor<Object> removed = ArgumentCaptor.forClass(Object.class);
        verify(softDelete).setParameter(eq("ids"), removed.capture());
        assertEquals(List.of(droppedRow.getId()), removed.getValue());
        // 只新建真正新增的组件。
        ArgumentCaptor<GoodsBomItem> persisted = ArgumentCaptor.forClass(GoodsBomItem.class);
        verify(em, times(1)).persist(persisted.capture());
        assertSame(added, persisted.getValue().getComponent());
        assertEquals(2, persisted.getValue().getSortOrder());
        // 报数与全删再全建同口径：替换掉原有 2 个，写入 2 个。
        assertEquals(2, result.added());
        assertEquals(2, result.removed());
    }

    @Test
    void changedComponentIsOverwrittenInPlaceAndLosesItsAuditMark() {
        BomItemSaveRequest changed = line(kept, "2.5");
        changed.setSummary("改了用量");

        paste.paste(request(changed));

        assertEquals(0, new BigDecimal("2.5").compareTo(keptRow.getQty()));
        assertEquals("改了用量", keptRow.getSummary());
        assertNull(keptRow.getAuditedAt());
        assertNull(keptRow.getAuditedBy());
        verify(em, times(0)).persist(any());
        assertNotNull(keptRow.getId());
    }

    private BomPasteRequest request(BomItemSaveRequest... lines) {
        return new BomPasteRequest(BomPasteRequest.Mode.REPLACE,
                List.of(new BomPasteRequest.Target(target.getId(), null)), List.of(lines));
    }

    private static BomItemSaveRequest line(Goods component, String qty) {
        BomItemSaveRequest line = new BomItemSaveRequest();
        line.setComponentGoodsId(component.getId());
        line.setQty(new BigDecimal(qty));
        return line;
    }

    private GoodsBomItem row(Goods component, String qty, int sort) {
        GoodsBomItem row = new GoodsBomItem();
        row.setGoods(target);
        row.setComponent(component);
        row.setQty(new BigDecimal(qty));
        row.setSortOrder(sort);
        return row;
    }

    private static Goods goods(String code) {
        Goods goods = new Goods();
        goods.setCode(code);
        goods.setName("货品" + code);
        return goods;
    }
}
