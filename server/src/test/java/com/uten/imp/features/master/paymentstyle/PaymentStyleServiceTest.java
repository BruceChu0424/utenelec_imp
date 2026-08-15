package com.uten.imp.features.master.paymentstyle;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleSaveRequest;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleUpdateRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InOrder;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.jpa.repository.Modifying;

import java.lang.reflect.Method;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class PaymentStyleServiceTest {

    @Mock
    private PaymentStyleRepository repo;
    @Mock
    private EntityManager em;
    @Mock
    private TxSessionVars tx;
    @Mock
    private MasterCodeService masterCodeService;
    @Mock
    private Query hierarchyLockQuery;

    @BeforeEach
    void provideHierarchyLockForEveryUpdate() {
        lenient().when(em.createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY")))
                .thenReturn(hierarchyLockQuery);
    }

    @Test
    void createWithParentLocksHierarchyAndRejectsDifferentCategory() {
        UUID parentId = UUID.randomUUID();
        PaymentStyle parent = style("收入", "INCOME", "/031/");
        parent.setId(parentId);
        PaymentStyleSaveRequest request = new PaymentStyleSaveRequest();
        request.setName("办公费");
        request.setCategory("EXPENSE");
        request.setParentId(parentId);
        when(masterCodeService.nextCode(MasterCodePrefix.PAYMENT_STYLE)).thenReturn("SK000001");
        when(repo.findById(parentId)).thenReturn(Optional.of(parent));
        stubHierarchyLock();

        ApiException error = assertThrows(ApiException.class, () -> service().create(request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("必须与当前类别同属").contains("EXPENSE");
        verify(repo, never()).save(any(PaymentStyle.class));
        InOrder order = inOrder(em, hierarchyLockQuery, repo);
        order.verify(em).createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY"));
        order.verify(hierarchyLockQuery).getSingleResult();
        order.verify(repo).findById(parentId);
    }

    @Test
    void createRejectsReferencedLeafParentThatWouldBecomeDirectory() {
        UUID parentId = UUID.randomUUID();
        PaymentStyle parent = style("差旅费", "EXPENSE", "/CUSTOM/TRAVEL/");
        parent.setId(parentId);
        PaymentStyleSaveRequest request = new PaymentStyleSaveRequest();
        request.setName("境内差旅");
        request.setCategory("EXPENSE");
        request.setParentId(parentId);
        when(masterCodeService.nextCode(MasterCodePrefix.PAYMENT_STYLE)).thenReturn("SK000001");
        when(repo.findById(parentId)).thenReturn(Optional.of(parent));
        when(repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(parentId))
                .thenReturn(List.of());
        when(repo.hasBusinessReferences(parentId, false)).thenReturn(true);
        stubHierarchyLock();

        ApiException error = assertThrows(ApiException.class, () -> service().create(request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("已被财务业务引用").contains("不能再变为目录");
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void unchangedParentDoesNotCheckCycleOrRebuild() {
        PaymentStyle parent = style("费用", "EXPENSE", "/043/");
        PaymentStyle node = style("办公费", "EXPENSE", "/043/OFFICE/");
        node.setParent(parent);
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setParentId(parent.getId());
        stubExistingNode(node);
        stubHierarchyLock();

        service().update(node.getId(), request);

        assertSame(parent, node.getParent());
        verify(repo, never()).isDescendant(any(UUID.class), any(UUID.class));
        verify(repo, never()).rebuildSubtreeHierarchy(any(UUID.class));
        verify(em).refresh(node);
    }

    @Test
    void unchangedParentStillEnforcesCategoryInvariant() {
        PaymentStyle parent = style("收入", "INCOME", "/031/");
        PaymentStyle node = style("办公费", "EXPENSE", "/031/OFFICE/");
        node.setParent(parent);
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setParentId(parent.getId());
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(repo, never()).rebuildSubtreeHierarchy(node.getId());
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void explicitMoveToRootUsesAtomicRebuild() {
        PaymentStyle parent = style("费用", "EXPENSE", "/CUSTOM-EXPENSE/");
        PaymentStyle node = style("自定义费用", "EXPENSE", "/CUSTOM-EXPENSE/CUSTOM/");
        node.setParent(parent);
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setMoveToRoot(true);
        stubExistingNode(node);
        stubHierarchyLock();
        when(repo.rebuildSubtreeHierarchy(node.getId())).thenReturn(2);

        service().update(node.getId(), request);

        assertNull(node.getParent());
        verify(repo).rebuildSubtreeHierarchy(node.getId());
        verify(repo, never()).findSubtree(node.getId());
        verify(em, never()).refresh(node);
    }

    @Test
    void parentIdAndMoveToRootAreMutuallyExclusive() {
        PaymentStyleUpdateRequest request = updateRequest("办公费");
        request.setParentId(UUID.randomUUID());
        request.setMoveToRoot(true);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(UUID.randomUUID(), request));

        assertEquals(ErrorCode.BUSINESS, error.getCode());
        assertThat(error.getMessage()).contains("不能同时提交");
        verify(repo, never()).findById(any(UUID.class));
        verify(em, never()).createNativeQuery(anyString());
    }

    @Test
    void updateRejectsDifferentParentCategoryBeforeCycleCheckOrWrite() {
        PaymentStyle node = style("办公费", "EXPENSE", "/CUSTOM/OFFICE/");
        PaymentStyle parent = style("销售收入", "INCOME", "/031/");
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setParentId(parent.getId());
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        when(repo.findById(parent.getId())).thenReturn(Optional.of(parent));
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(repo, never()).isDescendant(node.getId(), parent.getId());
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void movingSubtreeWithHistoricalReferenceIsRejectedBeforeWrite() {
        PaymentStyle node = style("差旅费用", "EXPENSE", "/CUSTOM/TRAVEL/");
        PaymentStyle target = style("管理费用", "EXPENSE", "/CUSTOM/MANAGE/");
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setParentId(target.getId());
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        when(repo.findById(target.getId())).thenReturn(Optional.of(target));
        when(repo.isDescendant(node.getId(), target.getId())).thenReturn(false);
        when(repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(target.getId()))
                .thenReturn(List.of(new PaymentStyle()));
        when(repo.hasBusinessReferences(node.getId(), true)).thenReturn(true);
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("子类别").contains("历史引用").contains("不能移动");
        verify(repo, never()).save(any(PaymentStyle.class));
        verify(repo, never()).rebuildSubtreeHierarchy(node.getId());
    }

    @Test
    void activeNodeCannotMoveUnderDisabledParentWithoutStatusField() {
        PaymentStyle node = style("市场费用", "EXPENSE", "/CUSTOM/MARKETING/");
        PaymentStyle target = style("旧目录", "EXPENSE", "/CUSTOM/OLD/");
        target.setStatus("禁用");
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setParentId(target.getId());
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        when(repo.findById(target.getId())).thenReturn(Optional.of(target));
        when(repo.isDescendant(node.getId(), target.getId())).thenReturn(false);
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("已禁用类别");
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void protectedSystemPathCannotMove() {
        PaymentStyle node = style("管理费用", "EXPENSE", "/043/");
        PaymentStyle target = style("其它费用", "EXPENSE", "/CUSTOM/");
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setParentId(target.getId());
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("系统科目").contains("不能移动");
        verify(repo, never()).findById(target.getId());
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void autoCreatedPlaceholderWithoutSystemIdentityCanBeRenamed() {
        PaymentStyle node = style("自动补录费用", "EXPENSE", "/CUSTOM/AUTO/");
        node.setAutoCreated(true);
        PaymentStyleUpdateRequest request = updateRequest("银行费用");
        stubExistingNode(node);

        service().update(node.getId(), request);

        assertEquals("银行费用", node.getName());
        verify(repo).save(node);
        InOrder order = inOrder(em, hierarchyLockQuery, repo);
        order.verify(em).createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY"));
        order.verify(hierarchyLockQuery).getSingleResult();
        order.verify(repo).findById(node.getId());
    }

    @Test
    void preexistingExpenseStyleSelectedByHardCodedNameCannotBeRenamed() {
        PaymentStyle node = style("汇兑损益", "EXPENSE", "/CUSTOM/FX/");
        PaymentStyleUpdateRequest request = updateRequest("汇率调整");
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("汇兑损益", node.getName());
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void ordinaryExpenseCannotClaimReservedSystemName() {
        PaymentStyleSaveRequest create = new PaymentStyleSaveRequest();
        create.setName("手续费");
        create.setCategory("EXPENSE");

        ApiException createError = assertThrows(
                ApiException.class,
                () -> service().create(create));
        assertEquals(ErrorCode.CONFLICT, createError.getCode());

        PaymentStyle node = style("银行费用", "EXPENSE", "/CUSTOM/BANK/");
        PaymentStyleUpdateRequest update = updateRequest("汇兑损益");
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));

        ApiException updateError = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), update));

        assertEquals(ErrorCode.CONFLICT, updateError.getCode());
        assertThat(updateError.getMessage()).contains("系统保留科目名称");
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void protectedSystemStyleCannotBeDisabled() {
        PaymentStyle node = style("应收账款", "ACCOUNT", "/113/");
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setStatus("禁用");
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("系统科目").contains("使用").contains("过账");
        assertEquals("使用", node.getStatus());
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void statusOnlyAcceptsStableUseOrDisabledValues() {
        PaymentStyle node = style("办公费", "EXPENSE", "/CUSTOM/OFFICE/");
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setStatus("停用");
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.BUSINESS, error.getCode());
        assertThat(error.getMessage()).contains("使用").contains("禁用");
        assertEquals("使用", node.getStatus());
        verify(repo, never()).save(any(PaymentStyle.class));
        verify(hierarchyLockQuery).getSingleResult();
    }

    @Test
    void disabledParentCannotReceiveNewChild() {
        UUID parentId = UUID.randomUUID();
        PaymentStyle parent = style("旧费用目录", "EXPENSE", "/CUSTOM/OLD/");
        parent.setId(parentId);
        parent.setStatus("禁用");
        PaymentStyleSaveRequest request = new PaymentStyleSaveRequest();
        request.setName("新费用");
        request.setCategory("EXPENSE");
        request.setParentId(parentId);
        when(masterCodeService.nextCode(MasterCodePrefix.PAYMENT_STYLE)).thenReturn("SK000001");
        when(repo.findById(parentId)).thenReturn(Optional.of(parent));
        stubHierarchyLock();

        ApiException error = assertThrows(ApiException.class, () -> service().create(request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("已禁用类别");
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void statusOnlyUpdateDoesNotRequireOrOverwriteName() {
        PaymentStyle node = style("办公费", "EXPENSE", "/CUSTOM/OFFICE/");
        PaymentStyleUpdateRequest request = new PaymentStyleUpdateRequest();
        request.setStatus("禁用");
        stubExistingNode(node);
        when(repo.findSubtree(node.getId())).thenReturn(List.of(node));

        service().update(node.getId(), request);

        assertEquals("办公费", node.getName());
        assertEquals("禁用", node.getStatus());
        verify(repo).save(node);
    }

    @Test
    void styleReferencedByActiveAccountCannotBeDisabled() {
        PaymentStyle node = style("自定义银行科目", "ACCOUNT", "/CUSTOM/BANK/");
        PaymentStyleUpdateRequest request = new PaymentStyleUpdateRequest();
        request.setStatus("禁用");
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        when(repo.hasActiveAccountReferences(node.getId())).thenReturn(true);
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("使用中的账户").contains("不能停用");
        assertEquals("使用", node.getStatus());
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void directoryWithActiveDescendantCannotBeDisabled() {
        PaymentStyle root = style("自定义费用", "EXPENSE", "/CUSTOM/");
        PaymentStyle activeChild = style("办公费", "EXPENSE", "/CUSTOM/OFFICE/");
        activeChild.setParent(root);
        PaymentStyleUpdateRequest request = updateRequest(root.getName());
        request.setStatus("禁用");
        when(repo.findById(root.getId())).thenReturn(Optional.of(root));
        when(repo.findSubtree(root.getId())).thenReturn(List.of(root, activeChild));
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(root.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("使用中的子类别").contains("不能停用");
        assertEquals("使用", root.getStatus());
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void enabledNodeRequiresActiveAncestors() {
        PaymentStyle parent = style("旧目录", "EXPENSE", "/CUSTOM/OLD/");
        parent.setStatus("禁用");
        PaymentStyle node = style("旧费用", "EXPENSE", "/CUSTOM/OLD/ITEM/");
        node.setStatus("禁用");
        node.setParent(parent);
        PaymentStyleUpdateRequest request = updateRequest(node.getName());
        request.setStatus("使用");
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        stubHierarchyLock();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("已禁用的上级").contains("不能启用");
        assertEquals("禁用", node.getStatus());
        verify(repo, never()).save(any(PaymentStyle.class));
    }

    @Test
    void deleteAlwaysRejectsAndSuggestsDisableToAvoidReferenceRace() {
        PaymentStyle node = style("办公费", "EXPENSE", "/CUSTOM/OFFICE/");
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        stubHierarchyLock();

        ApiException error = assertThrows(ApiException.class, () -> service().delete(node.getId()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("不能直接删除").contains("禁用").contains("并发");
        assertFalse(node.isDeleted());
        verify(repo, never()).save(any(PaymentStyle.class));
        verify(repo, never()).hasBusinessReferences(any(UUID.class), any(boolean.class));
    }

    @Test
    void repositoryRebuildIsRecursiveAtomicAndAuditAware() throws Exception {
        Method method = PaymentStyleRepository.class.getMethod(
                "rebuildSubtreeHierarchy", UUID.class);
        org.springframework.data.jpa.repository.Query query =
                method.getAnnotation(org.springframework.data.jpa.repository.Query.class);
        Modifying modifying = method.getAnnotation(Modifying.class);
        String sql = query.value().toLowerCase().replaceAll("\\s+", " ");

        assertThat(sql)
                .contains("with recursive rebuilt")
                .contains("join rebuilt parent on child.parent_id = parent.id")
                .contains("set level = rebuilt.new_level")
                .contains("path = rebuilt.new_path")
                .contains("updated_at = now()")
                .contains("current_setting('app.actor_id', true)")
                .contains("where not child.id = any(parent.visited)")
                .doesNotContain("child.is_deleted = false")
                .doesNotContain("order by");
        assertThat(modifying.flushAutomatically()).isTrue();
        assertThat(modifying.clearAutomatically()).isTrue();
    }

    @Test
    void repositoryReferenceCheckCoversEveryCurrentExternalUuidFkWithoutLegacyFallback()
            throws Exception {
        Method method = PaymentStyleRepository.class.getMethod(
                "hasBusinessReferences", UUID.class, boolean.class);
        org.springframework.data.jpa.repository.Query query =
                method.getAnnotation(org.springframework.data.jpa.repository.Query.class);
        String sql = query.value().toLowerCase().replaceAll("\\s+", " ");

        assertThat(sql)
                .contains("with recursive style_subtree")
                .contains("join style_subtree parent on child.parent_id = parent.id")
                .contains("not child.id = any(parent.visited)")
                .contains("from gl_entries")
                .contains("from fixed_assets")
                .contains("from deferred_expenses")
                .contains("from expense_claims")
                .contains("from finance_asset_categories")
                .contains("from finance_asset_books")
                .contains("from finance_deferral_schedule_versions")
                .contains("from finance_asset_posting_lines")
                .contains("from finance_receipts")
                .contains("from finance_expense_items")
                .contains("from finance_other_income_items")
                .contains("from accounts")
                .contains("style_id in (select id from style_subtree)")
                .doesNotContain("style_legacy_id")
                .doesNotContain("is_deleted");
    }

    private PaymentStyleService service() {
        return new PaymentStyleService(repo, em, tx, masterCodeService);
    }

    private void stubExistingNode(PaymentStyle node) {
        when(repo.findById(node.getId())).thenReturn(Optional.of(node));
        when(repo.findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(node.getId()))
                .thenReturn(List.of());
        when(repo.save(node)).thenReturn(node);
    }

    private void stubHierarchyLock() {
        when(em.createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY")))
                .thenReturn(hierarchyLockQuery);
    }

    private static PaymentStyleUpdateRequest updateRequest(String name) {
        PaymentStyleUpdateRequest request = new PaymentStyleUpdateRequest();
        request.setName(name);
        return request;
    }

    private static PaymentStyle style(String name, String category, String path) {
        PaymentStyle style = new PaymentStyle();
        style.setCode("STYLE-" + UUID.randomUUID());
        style.setName(name);
        style.setCategory(category);
        style.setPath(path);
        style.setStatus("使用");
        return style;
    }
}
