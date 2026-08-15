package com.uten.imp.legacy.migration;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.SystemMasterCategories;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.mouldcategory.MouldCategoryRepository;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import com.uten.imp.legacy.reader.LegacyCategoryRow;
import com.uten.imp.legacy.reader.LegacyCategorySource;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class LegacyCategoryCodePreservationTest {

    private static final LegacyCategoryRow LEGACY =
            new LegacyCategoryRow(101, 0, "OLD-V6", "旧库分类");

    @Test
    void hierarchyMigratorsCreateTheRealSystemRootEvenWhenLegacyTreesAreEmpty() {
        LegacyCategorySource emptySource = mock(LegacyCategorySource.class);
        when(emptySource.readCategoryTree(anyInt())).thenReturn(List.of());

        MouldCategoryRepository moulds = mock(MouldCategoryRepository.class);
        when(moulds.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        new MouldCategoryMigrator(emptySource, moulds, legacyImportEntityManager(),
                mock(TxSessionVars.class), mock(MasterCodeService.class)).migrateMoulds();
        var mouldCaptor = org.mockito.ArgumentCaptor.forClass(MouldCategory.class);
        verify(moulds).save(mouldCaptor.capture());
        assertSystemRoot(mouldCaptor.getValue(), SystemMasterCategories.MOULD_CODE);

        ClientCategoryRepository clients = mock(ClientCategoryRepository.class);
        when(clients.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        new ClientCategoryMigrator(emptySource, clients, legacyImportEntityManager(),
                mock(TxSessionVars.class), mock(MasterCodeService.class)).migrateClients();
        var clientCaptor = org.mockito.ArgumentCaptor.forClass(ClientCategory.class);
        verify(clients).save(clientCaptor.capture());
        assertSystemRoot(clientCaptor.getValue(), SystemMasterCategories.CLIENT_CODE);

        SupplierCategoryRepository suppliers = mock(SupplierCategoryRepository.class);
        when(suppliers.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        new SupplierCategoryMigrator(emptySource, suppliers, legacyImportEntityManager(),
                mock(TxSessionVars.class), mock(MasterCodeService.class)).migrateSuppliers();
        var supplierCaptor = org.mockito.ArgumentCaptor.forClass(SupplierCategory.class);
        verify(suppliers).save(supplierCaptor.capture());
        assertSystemRoot(supplierCaptor.getValue(), SystemMasterCategories.SUPPLIER_CODE);
    }

    @Test
    void materialCategory_initializesTraceOnceAndPreservesUserFieldsOnRerun() {
        LegacyCategorySource source = source();
        MaterialCategoryRepository repo = mock(MaterialCategoryRepository.class);
        MasterCodeService codes = mock(MasterCodeService.class);
        when(codes.nextCode(MasterCodePrefix.CATEGORY)).thenReturn("FL000001");
        when(repo.findByLegacyId(101)).thenReturn(Optional.empty());
        when(repo.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        MaterialCategoryMigrator migrator = new MaterialCategoryMigrator(
                source, repo, legacyImportEntityManager(), mock(TxSessionVars.class), codes);

        migrator.migrateGoods();
        MaterialCategory category = savedMaterial(repo);
        assertInitialized(category, "FL000001");

        category.setCode("FL009999");
        category.setRemark("用户备注");
        category.setCodePrefix("V6");
        when(repo.findByLegacyId(101)).thenReturn(Optional.of(category));
        migrator.migrateGoods();

        assertPreserved(category);
        verify(codes, times(1)).nextCode(MasterCodePrefix.CATEGORY);
    }

    @Test
    void mouldCategory_initializesTraceOnceAndPreservesUserFieldsOnRerun() {
        LegacyCategorySource source = source();
        MouldCategoryRepository repo = mock(MouldCategoryRepository.class);
        MasterCodeService codes = mock(MasterCodeService.class);
        when(codes.nextCode(MasterCodePrefix.MOULD_CATEGORY)).thenReturn("MF000001");
        when(repo.findByLegacyId(101)).thenReturn(Optional.empty());
        when(repo.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        MouldCategoryMigrator migrator = new MouldCategoryMigrator(
                source, repo, legacyImportEntityManager(), mock(TxSessionVars.class), codes);

        migrator.migrateMoulds();
        MouldCategory category = savedMould(repo);
        assertInitialized(category, "MF000001");

        category.setCode("MF009999");
        category.setRemark("用户备注");
        category.setCodePrefix("V6");
        when(repo.findByLegacyId(101)).thenReturn(Optional.of(category));
        migrator.migrateMoulds();

        assertPreserved(category);
        verify(codes, times(1)).nextCode(MasterCodePrefix.MOULD_CATEGORY);
    }

    @Test
    void clientCategory_initializesTraceOnceAndPreservesUserFieldsOnRerun() {
        LegacyCategorySource source = source();
        ClientCategoryRepository repo = mock(ClientCategoryRepository.class);
        MasterCodeService codes = mock(MasterCodeService.class);
        when(codes.nextCode(MasterCodePrefix.CLIENT_CATEGORY)).thenReturn("KF000001");
        when(repo.findByLegacyId(101)).thenReturn(Optional.empty());
        when(repo.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        ClientCategoryMigrator migrator = new ClientCategoryMigrator(
                source, repo, legacyImportEntityManager(), mock(TxSessionVars.class), codes);

        migrator.migrateClients();
        ClientCategory category = savedClient(repo);
        assertInitialized(category, "KF000001");

        category.setCode("KF009999");
        category.setRemark("用户备注");
        category.setCodePrefix("V6");
        when(repo.findByLegacyId(101)).thenReturn(Optional.of(category));
        migrator.migrateClients();

        assertPreserved(category);
        verify(codes, times(1)).nextCode(MasterCodePrefix.CLIENT_CATEGORY);
    }

    @Test
    void supplierCategory_initializesTraceOnceAndPreservesUserFieldsOnRerun() {
        LegacyCategorySource source = source();
        SupplierCategoryRepository repo = mock(SupplierCategoryRepository.class);
        MasterCodeService codes = mock(MasterCodeService.class);
        when(codes.nextCode(MasterCodePrefix.SUPPLIER_CATEGORY)).thenReturn("GF000001");
        when(repo.findByLegacyId(101)).thenReturn(Optional.empty());
        when(repo.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        SupplierCategoryMigrator migrator = new SupplierCategoryMigrator(
                source, repo, legacyImportEntityManager(), mock(TxSessionVars.class), codes);

        migrator.migrateSuppliers();
        SupplierCategory category = savedSupplier(repo);
        assertInitialized(category, "GF000001");

        category.setCode("GF009999");
        category.setRemark("用户备注");
        category.setCodePrefix("V6");
        when(repo.findByLegacyId(101)).thenReturn(Optional.of(category));
        migrator.migrateSuppliers();

        assertPreserved(category);
        verify(codes, times(1)).nextCode(MasterCodePrefix.SUPPLIER_CATEGORY);
    }

    private static LegacyCategorySource source() {
        LegacyCategorySource source = mock(LegacyCategorySource.class);
        when(source.readCategoryTree(anyInt())).thenReturn(List.of(LEGACY));
        return source;
    }

    private static EntityManager legacyImportEntityManager() {
        EntityManager entityManager = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn("on");
        return entityManager;
    }

    private static MaterialCategory savedMaterial(MaterialCategoryRepository repo) {
        var captor = org.mockito.ArgumentCaptor.forClass(MaterialCategory.class);
        verify(repo).save(captor.capture());
        return captor.getValue();
    }

    private static MouldCategory savedMould(MouldCategoryRepository repo) {
        var captor = org.mockito.ArgumentCaptor.forClass(MouldCategory.class);
        verify(repo, atLeastOnce()).save(captor.capture());
        return captor.getAllValues().stream()
                .filter(category -> Integer.valueOf(101).equals(category.getLegacyId()))
                .findFirst().orElseThrow();
    }

    private static ClientCategory savedClient(ClientCategoryRepository repo) {
        var captor = org.mockito.ArgumentCaptor.forClass(ClientCategory.class);
        verify(repo, atLeastOnce()).save(captor.capture());
        return captor.getAllValues().stream()
                .filter(category -> Integer.valueOf(101).equals(category.getLegacyId()))
                .findFirst().orElseThrow();
    }

    private static SupplierCategory savedSupplier(SupplierCategoryRepository repo) {
        var captor = org.mockito.ArgumentCaptor.forClass(SupplierCategory.class);
        verify(repo, atLeastOnce()).save(captor.capture());
        return captor.getAllValues().stream()
                .filter(category -> Integer.valueOf(101).equals(category.getLegacyId()))
                .findFirst().orElseThrow();
    }

    private static void assertInitialized(MaterialCategory c, String generatedCode) {
        assertEquals(generatedCode, c.getCode());
        assertEquals(LEGACY.code(), c.getRemark());
        assertEquals(LEGACY.code(), c.getLegacyCodeSnapshot());
    }

    private static void assertInitialized(MouldCategory c, String generatedCode) {
        assertEquals(generatedCode, c.getCode());
        assertEquals(LEGACY.code(), c.getRemark());
        assertEquals(LEGACY.code(), c.getLegacyCodeSnapshot());
    }

    private static void assertInitialized(ClientCategory c, String generatedCode) {
        assertEquals(generatedCode, c.getCode());
        assertEquals(LEGACY.code(), c.getRemark());
        assertEquals(LEGACY.code(), c.getLegacyCodeSnapshot());
    }

    private static void assertInitialized(SupplierCategory c, String generatedCode) {
        assertEquals(generatedCode, c.getCode());
        assertEquals(LEGACY.code(), c.getRemark());
        assertEquals(LEGACY.code(), c.getLegacyCodeSnapshot());
    }

    private static void assertPreserved(MaterialCategory c) {
        assertEquals("FL009999", c.getCode());
        assertEquals("用户备注", c.getRemark());
        assertEquals("V6", c.getCodePrefix());
        assertEquals(LEGACY.code(), c.getLegacyCodeSnapshot());
    }

    private static void assertPreserved(MouldCategory c) {
        assertEquals("MF009999", c.getCode());
        assertEquals("用户备注", c.getRemark());
        assertEquals("V6", c.getCodePrefix());
        assertEquals(LEGACY.code(), c.getLegacyCodeSnapshot());
    }

    private static void assertPreserved(ClientCategory c) {
        assertEquals("KF009999", c.getCode());
        assertEquals("用户备注", c.getRemark());
        assertEquals("V6", c.getCodePrefix());
        assertEquals(LEGACY.code(), c.getLegacyCodeSnapshot());
    }

    private static void assertPreserved(SupplierCategory c) {
        assertEquals("GF009999", c.getCode());
        assertEquals("用户备注", c.getRemark());
        assertEquals("V6", c.getCodePrefix());
        assertEquals(LEGACY.code(), c.getLegacyCodeSnapshot());
    }

    private static void assertSystemRoot(MouldCategory category, String code) {
        assertEquals(SystemMasterCategories.UNCATEGORIZED_LEGACY_ID, category.getLegacyId());
        assertEquals(code, category.getCode());
        assertEquals(SystemMasterCategories.UNCATEGORIZED_NAME, category.getName());
        assertEquals(SystemMasterCategories.SYSTEM_REMARK, category.getRemark());
        assertNull(category.getParent());
        assertNull(category.getCodePrefix());
        assertEquals(Integer.MAX_VALUE, category.getSortOrder());
        assertFalse(category.isDeleted());
    }

    private static void assertSystemRoot(ClientCategory category, String code) {
        assertEquals(SystemMasterCategories.UNCATEGORIZED_LEGACY_ID, category.getLegacyId());
        assertEquals(code, category.getCode());
        assertEquals(SystemMasterCategories.UNCATEGORIZED_NAME, category.getName());
        assertEquals(SystemMasterCategories.SYSTEM_REMARK, category.getRemark());
        assertNull(category.getParent());
        assertNull(category.getCodePrefix());
        assertEquals(Integer.MAX_VALUE, category.getSortOrder());
        assertFalse(category.isDeleted());
    }

    private static void assertSystemRoot(SupplierCategory category, String code) {
        assertEquals(SystemMasterCategories.UNCATEGORIZED_LEGACY_ID, category.getLegacyId());
        assertEquals(code, category.getCode());
        assertEquals(SystemMasterCategories.UNCATEGORIZED_NAME, category.getName());
        assertEquals(SystemMasterCategories.SYSTEM_REMARK, category.getRemark());
        assertNull(category.getParent());
        assertNull(category.getCodePrefix());
        assertEquals(Integer.MAX_VALUE, category.getSortOrder());
        assertFalse(category.isDeleted());
    }
}
