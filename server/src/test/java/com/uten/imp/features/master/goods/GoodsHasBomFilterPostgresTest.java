package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.features.master.client.Client;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.FacetBucket;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.Mould;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.supplier.Supplier;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.GoodsReadScopePolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.tuple;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 「组装信息」表头筛选的服务端契约：真实 Hibernate + 迁移后 goods/goods_bom_items 结构上，
 * hasBom=true/false 与列表 hasBom 投影逐行同口径（对齐 GoodsListLocationEndToEndTest：已删除边、
 * 停用组件退役边不算在用组装信息；迁移占位父件/组件不算；停用父件保留自己的在用配方），
 * facets/候选计数与选中该桶后的列表总数一致，定位与导出复用同一谓词。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsHasBomFilterPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static jakarta.persistence.EntityManagerFactory emf;
    private static JdbcTemplate db;
    private EntityManager em;
    private GoodsService service;

    // 父件
    private UUID activeParent, deletedEdgeParent, stubComponentParent, stubParent, plainGoods,
            disabledParent, mixedParent, retiredEdgeParent, disabledComponentParent;
    // 组件
    private UUID part, secondPart, stubPart, retiredPart, disabledPart;

    @BeforeAll
    static void baseline() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("goods_has_bom_filter");
        try (var connection = database.openConnection(); var statement = connection.createStatement()) {
            statement.execute("CREATE SCHEMA goods_has_bom_oracle");
            statement.execute("SET search_path=goods_has_bom_oracle,public");
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection, "goods", "goods_bom_items", "colors",
                    "units", "currencies", "material_categories", "moulds", "mould_categories", "clients",
                    "client_categories", "suppliers", "supplier_categories", "stock_balances", "warehouses",
                    "employees", "departments", "positions");
        }
        var source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        var properties = new java.util.Properties();
        properties.setProperty("currentSchema", "goods_has_bom_oracle,public");
        source.setConnectionProperties(properties);
        db = new JdbcTemplate(source);
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(source);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(Goods.class.getName(), GoodsBomItem.class.getName(),
                Color.class.getName(), Unit.class.getName(), com.uten.imp.features.master.currency.Currency.class.getName(),
                MaterialCategory.class.getName(), Mould.class.getName(), MouldCategory.class.getName(),
                Client.class.getName(), ClientCategory.class.getName(), Supplier.class.getName(),
                SupplierCategory.class.getName(), com.uten.imp.features.master.warehouse.Warehouse.class.getName(),
                com.uten.imp.features.org.employee.Employee.class.getName(),
                com.uten.imp.features.org.department.Department.class.getName(),
                com.uten.imp.features.org.position.Position.class.getName()));
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none", "hibernate.jdbc.time_zone", "UTC"));
        factory.afterPropertiesSet();
        emf = factory.getObject();
    }

    @AfterAll
    static void close() throws Exception {
        if (emf != null) emf.close();
        if (database != null) database.close();
    }

    @BeforeEach
    void seed() {
        db.execute("TRUNCATE goods,goods_bom_items,stock_balances,warehouses");
        part = goods("C-PART", null, false, "使用");
        secondPart = goods("C-PART2", null, false, "使用");
        stubPart = goods("C-STUB", null, true, "使用");
        retiredPart = goods("C-RETIRED", null, false, "禁用");
        disabledPart = goods("C-DISABLED", null, false, "禁用");
        activeParent = goods("P-ACTIVE", "S1", false, "使用");
        edge(activeParent, part, false);
        deletedEdgeParent = goods("P-DELETED-EDGE", "S2", false, "使用");
        edge(deletedEdgeParent, part, true);
        stubComponentParent = goods("P-STUB-COMPONENT", null, false, "使用");
        edge(stubComponentParent, stubPart, false);
        stubParent = goods("P-STUB-PARENT", null, true, "使用");
        edge(stubParent, part, false);
        plainGoods = goods("P-PLAIN", null, false, "使用");
        disabledParent = goods("P-DISABLED", "S1", false, "禁用");
        edge(disabledParent, part, false);
        mixedParent = goods("P-MIXED", "S1", false, "使用");
        edge(mixedParent, part, true);
        edge(mixedParent, secondPart, false);
        retiredEdgeParent = goods("P-RETIRED-EDGE", null, false, "使用");
        UUID retired = edge(retiredEdgeParent, retiredPart, true);
        db.update("UPDATE goods_bom_items SET retirement_reason='COMPONENT_DISABLED' WHERE id=?", retired);
        disabledComponentParent = goods("P-DISABLED-COMPONENT", "S2", false, "使用");
        edge(disabledComponentParent, disabledPart, false);

        em = emf.createEntityManager();
        var repositories = new JpaRepositoryFactory(em);
        var scope = mock(GoodsReadScopePolicy.class);
        when(scope.evaluate()).thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
        var actor = mock(SecurityContextCurrentUser.class);
        when(actor.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reader",
                Set.of("goods:view", "goods:export"), false, true, false)));
        service = new GoodsService(repositories.getRepository(GoodsRepository.class), mock(MaterialCategoryRepository.class),
                mock(ColorRepository.class), mock(UnitRepository.class), mock(MouldRepository.class),
                mock(TxSessionVars.class), em, mock(CategoryDrivenCodeService.class), mock(OwnerVisibility.class), actor,
                mock(GoodsCostMasker.class), mock(GoodsMasterRelationshipResolver.class), scope);
    }

    @AfterEach
    void closeEntityManager() {
        if (em != null) em.close();
    }

    @Test
    void bothDirectionsPartitionTheScopeExactlyLikeTheListProjectionIncludingRetiredAndStubEdges() {
        GoodsQueryFilter everything = filter(false, false);
        var all = service.list(everything, 1, 100, null, null);
        Set<UUID> projected = all.getItems().stream().filter(GoodsListItem::isHasBom)
                .map(GoodsListItem::getId).collect(Collectors.toSet());
        assertThat(projected).as("list projection (GoodsListLocationEndToEndTest semantics)")
                .containsExactlyInAnyOrder(activeParent, disabledParent, mixedParent, disabledComponentParent);

        var present = service.list(everything.withHasBom(true), 1, 100, null, null);
        var absent = service.list(everything.withHasBom(false), 1, 100, null, null);
        assertThat(ids(present.getItems())).containsExactlyInAnyOrderElementsOf(projected);
        assertThat(present.getItems()).allMatch(GoodsListItem::isHasBom);
        assertThat(absent.getItems()).noneMatch(GoodsListItem::isHasBom);
        Set<UUID> complement = new HashSet<>(ids(all.getItems()));
        complement.removeAll(projected);
        assertThat(ids(absent.getItems())).containsExactlyInAnyOrderElementsOf(complement)
                .contains(deletedEdgeParent, stubComponentParent, stubParent, plainGoods, retiredEdgeParent,
                        part, stubPart);
        assertThat(present.getTotal() + absent.getTotal()).isEqualTo(all.getTotal()).isEqualTo(14);
        assertThat(present.getTotal()).isEqualTo(4);
    }

    @Test
    void browsingScopeFacetsAndCandidatesCountWhatTheListReturnsForEachBucket() {
        GoodsQueryFilter browsing = filter(true, true);
        assertThat(ids(service.list(browsing.withHasBom(true), 1, 100, null, null).getItems()))
                .containsExactlyInAnyOrder(activeParent, mixedParent, disabledComponentParent);
        assertThat(ids(service.list(browsing.withHasBom(false), 1, 100, null, null).getItems()))
                .containsExactlyInAnyOrder(deletedEdgeParent, stubComponentParent, plainGoods, retiredEdgeParent,
                        part, secondPart);

        assertThat(service.queryFacets(browsing).getHasBom())
                .extracting(FacetBucket::getValue, FacetBucket::getCount, FacetBucket::getLabel)
                .containsExactly(tuple("true", 3L, "有组装信息"), tuple("false", 6L, "无组装信息"));
        // 本字段选中值在自己的桶里放开；其他表头桶照常受它约束。
        var selected = service.queryFacets(browsing.withHasBom(true));
        assertThat(selected.getHasBom()).extracting(FacetBucket::getValue, FacetBucket::getCount)
                .containsExactly(tuple("true", 3L), tuple("false", 6L));
        assertThat(selected.getSeries()).extracting(FacetBucket::getValue, FacetBucket::getCount)
                .containsExactlyInAnyOrder(tuple("S1", 2L), tuple("S2", 1L));
        assertThat(selected.getNullCounts()).containsEntry("series", 0L).doesNotContainKey("hasBom");
        var withoutBom = service.queryFacets(browsing.withHasBom(false));
        assertThat(withoutBom.getSeries()).extracting(FacetBucket::getValue, FacetBucket::getCount)
                .containsExactly(tuple("S2", 1L));
        assertThat(withoutBom.getNullCounts()).containsEntry("series", 5L);
        // 其他筛选同样收窄组装信息桶；计数为 0 的桶照样下发。
        var s1 = series(browsing, "S1");
        assertThat(service.queryFacets(s1).getHasBom()).extracting(FacetBucket::getValue, FacetBucket::getCount)
                .containsExactly(tuple("true", 2L), tuple("false", 0L));
        assertThat(service.queryFacets(series(browsing, "S2")).getHasBom())
                .extracting(FacetBucket::getValue, FacetBucket::getCount)
                .containsExactly(tuple("true", 1L), tuple("false", 1L));

        var candidates = service.facetValues(browsing.withHasBom(true), "hasBom", "", 1, 50);
        assertThat(candidates.items()).extracting(FacetBucket::getValue, FacetBucket::getCount, FacetBucket::getLabel)
                .containsExactly(tuple("true", 3L, "有组装信息"), tuple("false", 6L, "无组装信息"));
        assertThat(candidates.hasMore()).isFalse();
        assertThat(service.facetValues(browsing, "hasBom", "无", 1, 50).items())
                .extracting(FacetBucket::getValue).containsExactly("false");
        assertThat(service.facetValues(browsing, "hasBom", "停用", 1, 50).items()).isEmpty();
        var first = service.facetValues(browsing, "hasBom", "", 1, 1);
        assertThat(first.items()).extracting(FacetBucket::getValue).containsExactly("true");
        assertThat(first.hasMore()).isTrue();
        var second = service.facetValues(browsing, "hasBom", "", 2, 1);
        assertThat(second.items()).extracting(FacetBucket::getValue).containsExactly("false");
        assertThat(second.hasMore()).isFalse();
        assertThat(service.facetValues(browsing, "hasBom", "", 3, 1).items()).isEmpty();
        assertThat(service.facetValues(s1, "hasBom", "", 1, 50).items())
                .extracting(FacetBucket::getValue, FacetBucket::getCount)
                .containsExactly(tuple("true", 2L), tuple("false", 0L));
    }

    @Test
    void locationAndExportUseTheSameAssemblyPredicate() {
        GoodsQueryFilter browsing = filter(true, true);
        assertThat(service.locate(browsing.withHasBom(true), activeParent, 100, null, null).found()).isTrue();
        assertThat(service.locate(browsing.withHasBom(false), activeParent, 100, null, null).found()).isFalse();
        assertThat(service.locate(browsing.withHasBom(false), retiredEdgeParent, 100, null, null).found()).isTrue();
        assertThat(service.locate(browsing.withHasBom(true), retiredEdgeParent, 100, null, null).found()).isFalse();

        var present = service.export(browsing.withHasBom(true), null, null);
        assertThat(present.total()).isEqualTo(3);
        assertThat(present.rows()).extracting(row -> row.get("goodsId"))
                .containsExactlyInAnyOrder(activeParent.toString(), mixedParent.toString(),
                        disabledComponentParent.toString());
        assertThat(present.rows()).allSatisfy(row -> assertThat((String) row.get("bomRef"))
                .endsWith(GoodsExportProjection.BOM_REF_SUFFIX));
        var absent = service.export(browsing.withHasBom(false), null, null);
        assertThat(absent.total()).isEqualTo(6);
        assertThat(absent.rows()).allSatisfy(row -> assertThat(row.get("bomRef")).isEqualTo(""));
    }

    private static GoodsQueryFilter filter(boolean excludeDisabled, boolean excludeStub) {
        return new GoodsQueryFilter(null, null, null, null, null, null, null, null, null, null, null, null, null, null,
                null, null, null, null, excludeDisabled, excludeStub, false, false, null, null, false);
    }

    private static GoodsQueryFilter series(GoodsQueryFilter base, String series) {
        return new GoodsQueryFilter(base.categoryId(), base.categoryRootIds(), base.keyword(), base.nullFields(), series,
                base.model(), base.material(), base.code(), base.name(), base.spec(), base.cNumber(),
                base.requireRemark(), base.mouldCode(), base.rearInsertCode(), base.paper(), base.colorLegacyId(),
                base.unitLegacyId(), base.sourceType(), base.excludeDisabled(), base.excludeStub(),
                base.disabledOnly(), base.stubOnly(), base.owningWarehouse(), base.owningWorkshop(),
                base.includeRelated(), base.columnSearch(), base.colorRef(), base.unitRef(), base.hasBom());
    }

    private static List<UUID> ids(List<GoodsListItem> rows) {
        return rows.stream().map(GoodsListItem::getId).toList();
    }

    private UUID goods(String code, String series, boolean autoCreated, String status) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,series,status,is_deleted,auto_created,code_managed,"
                        + "is_recycled_material,version) VALUES(?,?,?,?,?,false,?,false,false,0)",
                id, code, "货品" + code, series, status, autoCreated);
        return id;
    }

    private UUID edge(UUID parent, UUID component, boolean deleted) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,is_deleted,deleted_at) "
                        + "VALUES(?,?,?,1,?,CASE WHEN ? THEN now() END)",
                id, parent, component, deleted, deleted);
        return id;
    }
}
