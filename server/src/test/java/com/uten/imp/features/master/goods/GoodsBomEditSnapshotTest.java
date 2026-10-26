package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validator;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.SimpleTransactionStatus;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsBomEditSnapshotTest {
    final GoodsBomService bom = mock(GoodsBomService.class);
    final GoodsRepository repository = mock(GoodsRepository.class);
    final GoodsService goods = mock(GoodsService.class);
    final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    final Map<UUID, Goods> components = new LinkedHashMap<>();
    final Goods root = active();
    GoodsBomEditService edits;

    @BeforeEach void before() {
        login(Set.of("goods:view", "goods:edit", "goods:bom:edit"));
        when(repository.findById(root.getId())).thenReturn(Optional.of(root));
        when(repository.findAllById(any())).thenAnswer(call -> {
            List<Goods> found = new ArrayList<>();
            for (UUID id : call.<Iterable<UUID>>getArgument(0)) {
                if (components.containsKey(id)) found.add(components.get(id));
            }
            return found;
        });
        when(goods.canWrite(root)).thenReturn(true);
        when(goods.visibleWriteCapabilities(anyList())).thenAnswer(call -> {
            Map<UUID, Boolean> scope = new LinkedHashMap<>();
            for (Goods item : call.<List<Goods>>getArgument(0)) scope.put(item.getId(), true);
            return scope;
        });
        var transactions = mock(PlatformTransactionManager.class);
        when(transactions.getTransaction(any())).thenAnswer(call -> new SimpleTransactionStatus());
        var db = mock(NamedParameterJdbcTemplate.class);
        when(db.queryForObject(anyString(), anyMap(), eq(String.class))).thenReturn("state");
        var tx = mock(TxSessionVars.class);
        when(tx.hmac(anyString())).thenReturn("digest");
        edits = new GoodsBomEditService(bom, repository, mock(GoodsBomItemRepository.class),
                mock(GoodsBomGraphLock.class), mock(MasterReferenceValidationPort.class), current, db,
                mock(EntityManager.class), new ObjectMapper(), mock(Validator.class), transactions, tx,
                mock(GoodsBomHistoryPermissions.class), goods, mock(GoodsInlineEditService.class));
    }

    @AfterEach void after() { SecurityContextHolder.clearContext(); }

    @Test void largeImmediateComponentBatchIsBoundedAndNeverReadsDescendantRecipes() {
        List<BomItemView> items = new ArrayList<>();
        for (int index = 0; index < 501; index++) {
            Goods component = active();
            component.setVersion(8);
            component.setModel("model-" + index);
            components.put(component.getId(), component);
            items.add(edge(component.getId()));
        }
        items.add(items.getFirst()); // repeated occurrence must not repeat its lookup
        when(bom.list(root.getId())).thenReturn(items);
        var snapshot = edits.snapshot(root.getId());
        assertEquals(501, snapshot.componentGoods().size());
        assertTrue(snapshot.componentGoods().stream().allMatch(item -> item.version() == 8 && item.componentGoodsWritable()));
        verify(repository, times(3)).findAllById(argThat(ids ->
                java.util.stream.StreamSupport.stream(ids.spliterator(), false).count() <= 250));
        verify(repository).findById(root.getId());
        verifyNoMoreInteractions(repository);
        verify(bom).list(root.getId());
        verifyNoMoreInteractions(bom);
        assertEquals(Set.of("id", "version", "model", "spec", "material", "sourceType", "componentGoodsWritable"),
                new ObjectMapper().valueToTree(snapshot.componentGoods().getFirst()).properties().stream()
                        .map(Map.Entry::getKey).collect(java.util.stream.Collectors.toSet()));
    }

    @Test void omittedVisibilityAndInactiveComponentsCannotExposeEditableSnapshots() {
        Goods visible = active(), hidden = active(), disabled = active();
        disabled.setStatus("停用");
        for (Goods component : List.of(visible, hidden, disabled)) components.put(component.getId(), component);
        var items = List.of(edge(visible.getId()), edge(hidden.getId()), edge(disabled.getId()));
        when(bom.list(root.getId())).thenReturn(items);
        when(goods.visibleWriteCapabilities(anyList())).thenReturn(Map.of(visible.getId(), false, disabled.getId(), true));
        var snapshots = edits.snapshot(root.getId()).componentGoods();
        assertEquals(List.of(visible.getId()), snapshots.stream().map(GoodsBomEditService.GoodsSnapshot::id).toList());
        assertFalse(snapshots.getFirst().componentGoodsWritable());
    }

    @Test void bomOnlyOrMasterReadOnlyPermissionsDoNotRunComponentMasterLookup() {
        for (Set<String> grants : List.of(Set.of("goods:bom:edit"), Set.of("goods:view", "goods:bom:edit"))) {
            login(grants);
            var items = List.of(edge(UUID.randomUUID()));
            when(bom.list(root.getId())).thenReturn(items);
            assertTrue(edits.snapshot(root.getId()).componentGoods().isEmpty());
        }
        verify(repository, never()).findAllById(any());
    }

    @Test void componentScopeIsEvaluatedOnceAndRetainsReadOnlyAndHiddenOwnerBoundaries() {
        var owners = mock(OwnerVisibility.class);
        UUID writableOwner = UUID.randomUUID(), readOnlyOwner = UUID.randomUUID();
        when(owners.evaluate("goods", "goods:view:all")).thenReturn(
                new OwnerVisibility.OwnerScope(false, Set.of(writableOwner, readOnlyOwner), Set.of(writableOwner)));
        var actualGoods = new GoodsService(repository, mock(MaterialCategoryRepository.class), mock(ColorRepository.class),
                mock(UnitRepository.class), mock(MouldRepository.class), mock(TxSessionVars.class),
                mock(EntityManager.class), mock(CategoryDrivenCodeService.class), owners, current,
                mock(GoodsCostMasker.class), mock(GoodsMasterRelationshipResolver.class));
        ReflectionTestUtils.setField(ReflectionTestUtils.getField(actualGoods, "goodsReadScopePolicy"), "ownerScopeEnabled", true);
        Goods writable = active(), readOnly = active(), hidden = active(), unowned = active();
        writable.setOwnerEmployeeId(writableOwner);
        readOnly.setOwnerEmployeeId(readOnlyOwner);
        hidden.setOwnerEmployeeId(UUID.randomUUID());
        assertEquals(Map.of(writable.getId(), true, readOnly.getId(), false, unowned.getId(), true),
                actualGoods.visibleWriteCapabilities(List.of(writable, readOnly, hidden, unowned)));
        verify(owners).evaluate("goods", "goods:view:all");
        verifyNoMoreInteractions(owners);
    }

    void login(Set<String> grants) {
        var user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "bom-snapshot", grants, false, true, false);
        when(current.get()).thenReturn(Optional.of(user));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, "", user.getAuthorities()));
    }

    static Goods active() {
        Goods item = new Goods();
        item.setStatus("使用");
        return item;
    }

    static BomItemView edge(UUID component) {
        var row = mock(BomItemView.class);
        when(row.getComponentGoodsId()).thenReturn(component);
        return row;
    }
}
