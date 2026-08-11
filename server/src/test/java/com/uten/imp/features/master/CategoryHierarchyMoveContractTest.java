package com.uten.imp.features.master;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.master.clientcategory.ClientCategoryService;
import com.uten.imp.features.master.clientcategory.dto.ClientCategoryUpdateRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.master.materialcategory.dto.MaterialCategoryUpdateRequest;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.mouldcategory.MouldCategoryRepository;
import com.uten.imp.features.master.mouldcategory.MouldCategoryService;
import com.uten.imp.features.master.mouldcategory.dto.MouldCategoryUpdateRequest;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryService;
import com.uten.imp.features.master.suppliercategory.dto.SupplierCategoryUpdateRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.mockito.Answers;
import org.mockito.invocation.Invocation;
import org.springframework.data.jpa.repository.Modifying;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class CategoryHierarchyMoveContractTest {

    @ParameterizedTest
    @EnumSource(CategoryKind.class)
    void unchangedParentDoesNotCheckCycleOrRebuild(CategoryKind kind) throws Exception {
        Scenario scenario = scenario(kind, false);

        invokeUpdate(scenario);

        assertSame(scenario.currentParent, parentOf(scenario.kind, scenario.root));
        assertThat(callCount(scenario.repo, "isDescendant")).isZero();
        assertThat(callCount(scenario.repo, "rebuildSubtreeHierarchy")).isZero();
        assertThat(callCount(scenario.repo, "findSubtree")).isZero();
        assertThat(callCount(scenario.em, "createNativeQuery")).isEqualTo(1);
    }

    @ParameterizedTest
    @EnumSource(CategoryKind.class)
    void actualMoveKeepsCycleGuardAndUsesAtomicRebuild(CategoryKind kind) throws Exception {
        Scenario scenario = scenario(kind, false);
        scenario.requestedParentId = scenario.targetParentId;

        invokeUpdate(scenario);

        assertSame(scenario.targetParent, parentOf(scenario.kind, scenario.root));
        assertThat(callCount(scenario.repo, "isDescendant")).isEqualTo(1);
        assertThat(callCount(scenario.repo, "rebuildSubtreeHierarchy")).isEqualTo(1);
        assertThat(callCount(scenario.repo, "findSubtree")).isZero();
    }

    @ParameterizedTest
    @EnumSource(CategoryKind.class)
    void descendantMoveIsStillRejectedBeforeWriting(CategoryKind kind) throws Exception {
        Scenario scenario = scenario(kind, true);
        scenario.requestedParentId = scenario.targetParentId;

        InvocationTargetException thrown = assertThrows(
                InvocationTargetException.class,
                () -> invokeUpdate(scenario));

        assertInstanceOf(ApiException.class, thrown.getCause());
        assertSame(scenario.currentParent, parentOf(scenario.kind, scenario.root));
        assertThat(callCount(scenario.repo, "save")).isZero();
        assertThat(callCount(scenario.repo, "rebuildSubtreeHierarchy")).isZero();
    }

    @ParameterizedTest
    @EnumSource(CategoryKind.class)
    void repositoryRebuildFollowsParentLinksAndUpdatesActiveAndDeletedDescendants(
            CategoryKind kind) throws Exception {
        Method method = kind.repositoryClass.getMethod("rebuildSubtreeHierarchy", UUID.class);
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

    private static Scenario scenario(CategoryKind kind, boolean cycle) throws Exception {
        UUID rootId = UUID.randomUUID();
        UUID currentParentId = UUID.randomUUID();
        UUID targetParentId = UUID.randomUUID();
        Object currentParent = category(kind, currentParentId, "CURRENT", 1, "/CURRENT/");
        Object targetParent = category(kind, targetParentId, "TARGET", 2, "/TARGET/");
        Object root = category(kind, rootId, "ROOT", 2, "/CURRENT/ROOT/");
        setParent(kind, root, currentParent);

        Object repo = mock(kind.repositoryClass, invocation -> switch (invocation.getMethod().getName()) {
            case "findById" -> {
                UUID requestedId = invocation.getArgument(0);
                yield Optional.of(requestedId.equals(targetParentId) ? targetParent : root);
            }
            case "findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc" -> List.of();
            case "isDescendant" -> cycle;
            case "rebuildSubtreeHierarchy" -> 2;
            case "save" -> invocation.getArgument(0);
            default -> Answers.RETURNS_DEFAULTS.answer(invocation);
        });
        EntityManager em = mock(EntityManager.class);
        Query lockQuery = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(lockQuery);

        return new Scenario(
                kind, repo, em, mock(TxSessionVars.class), mock(MasterCodeService.class),
                root, currentParent, targetParent, currentParentId, targetParentId);
    }

    private static void invokeUpdate(Scenario scenario) throws Exception {
        Object service;
        if (scenario.kind.extraRepositoryClass != null) {
            // 模具分类服务构造函数额外注入 MouldRepository（移分类前校验模具归属）
            service = scenario.kind.serviceClass
                    .getConstructor(
                            scenario.kind.repositoryClass,
                            scenario.kind.extraRepositoryClass,
                            EntityManager.class,
                            TxSessionVars.class,
                            MasterCodeService.class)
                    .newInstance(scenario.repo, mock(scenario.kind.extraRepositoryClass),
                            scenario.em, scenario.tx, scenario.masterCodeService);
        } else {
            service = scenario.kind.serviceClass
                    .getConstructor(
                            scenario.kind.repositoryClass,
                            EntityManager.class,
                            TxSessionVars.class,
                            MasterCodeService.class)
                    .newInstance(scenario.repo, scenario.em, scenario.tx, scenario.masterCodeService);
        }
        Object request = scenario.kind.requestClass.getConstructor().newInstance();
        scenario.kind.requestClass.getMethod("setName", String.class)
                .invoke(request, "修改后名称");
        scenario.kind.requestClass.getMethod("setParentId", UUID.class)
                .invoke(request, scenario.requestedParentId);
        scenario.kind.serviceClass
                .getMethod("update", UUID.class, scenario.kind.requestClass)
                .invoke(service, idOf(scenario.kind, scenario.root), request);
    }

    private static Object category(
            CategoryKind kind, UUID id, String code, int level, String path) throws Exception {
        Object category = kind.entityClass.getConstructor().newInstance();
        kind.entityClass.getMethod("setId", UUID.class).invoke(category, id);
        kind.entityClass.getMethod("setCode", String.class).invoke(category, code);
        kind.entityClass.getMethod("setName", String.class).invoke(category, code);
        kind.entityClass.getMethod("setLevel", Integer.class).invoke(category, level);
        kind.entityClass.getMethod("setPath", String.class).invoke(category, path);
        return category;
    }

    private static void setParent(CategoryKind kind, Object category, Object parent) throws Exception {
        kind.entityClass.getMethod("setParent", kind.entityClass).invoke(category, parent);
    }

    private static Object parentOf(CategoryKind kind, Object category) throws Exception {
        return kind.entityClass.getMethod("getParent").invoke(category);
    }

    private static UUID idOf(CategoryKind kind, Object category) throws Exception {
        return (UUID) kind.entityClass.getMethod("getId").invoke(category);
    }

    private static long callCount(Object mock, String methodName) {
        return org.mockito.Mockito.mockingDetails(mock).getInvocations().stream()
                .map(Invocation::getMethod)
                .map(Method::getName)
                .filter(methodName::equals)
                .count();
    }

    private enum CategoryKind {
        MATERIAL(
                MaterialCategory.class,
                MaterialCategoryRepository.class,
                MaterialCategoryService.class,
                MaterialCategoryUpdateRequest.class,
                null),
        MOULD(
                MouldCategory.class,
                MouldCategoryRepository.class,
                MouldCategoryService.class,
                MouldCategoryUpdateRequest.class,
                MouldRepository.class),
        CLIENT(
                ClientCategory.class,
                ClientCategoryRepository.class,
                ClientCategoryService.class,
                ClientCategoryUpdateRequest.class,
                null),
        SUPPLIER(
                SupplierCategory.class,
                SupplierCategoryRepository.class,
                SupplierCategoryService.class,
                SupplierCategoryUpdateRequest.class,
                null);

        private final Class<?> entityClass;
        private final Class<?> repositoryClass;
        private final Class<?> serviceClass;
        private final Class<?> requestClass;
        private final Class<?> extraRepositoryClass;

        CategoryKind(
                Class<?> entityClass,
                Class<?> repositoryClass,
                Class<?> serviceClass,
                Class<?> requestClass,
                Class<?> extraRepositoryClass) {
            this.entityClass = entityClass;
            this.repositoryClass = repositoryClass;
            this.serviceClass = serviceClass;
            this.requestClass = requestClass;
            this.extraRepositoryClass = extraRepositoryClass;
        }
    }

    private static final class Scenario {
        private final CategoryKind kind;
        private final Object repo;
        private final EntityManager em;
        private final TxSessionVars tx;
        private final MasterCodeService masterCodeService;
        private final Object root;
        private final Object currentParent;
        private final Object targetParent;
        private final UUID currentParentId;
        private final UUID targetParentId;
        private UUID requestedParentId;

        private Scenario(
                CategoryKind kind,
                Object repo,
                EntityManager em,
                TxSessionVars tx,
                MasterCodeService masterCodeService,
                Object root,
                Object currentParent,
                Object targetParent,
                UUID currentParentId,
                UUID targetParentId) {
            this.kind = kind;
            this.repo = repo;
            this.em = em;
            this.tx = tx;
            this.masterCodeService = masterCodeService;
            this.root = root;
            this.currentParent = currentParent;
            this.targetParent = targetParent;
            this.currentParentId = currentParentId;
            this.targetParentId = targetParentId;
            this.requestedParentId = currentParentId;
        }
    }
}
