package com.uten.imp.features.stock.count;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.WorkshopStockCountPostingPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.Validator;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.access.prepost.PreAuthorize;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real PostgreSQL candidate/category SQL with the operational-warehouse function; never uses the business database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockCountCandidateCategoriesPostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private StockCountRequestService service;
    private SecurityContextCurrentUser user;
    private WorkshopStockCountPostingPort workshop;
    private final UUID leaf=UUID.randomUUID(),bin=UUID.randomUUID(),foreignBin=UUID.randomUUID();
    private final UUID kg=UUID.randomUUID(),pieces=UUID.randomUUID();

    @BeforeAll static void start() {
        PG.start();
        db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
    }
    @AfterAll static void stop() { PG.stop(); }

    @BeforeEach void seed() throws Exception {
        db.execute("""
                DROP SCHEMA public CASCADE; CREATE SCHEMA public;
                CREATE TABLE warehouses(id uuid PRIMARY KEY,code text,name text,parent_id uuid,status text DEFAULT '使用',
                  is_deleted boolean DEFAULT false,is_line_side boolean DEFAULT false,is_accountable boolean DEFAULT true);
                CREATE TABLE workshop_material_settings(periodic_bin_warehouse_id uuid,periodic_enabled boolean);
                CREATE TABLE units(id uuid PRIMARY KEY,name text,status text DEFAULT '使用',is_deleted boolean DEFAULT false);
                CREATE TABLE unit_measurement_profiles(unit_id uuid PRIMARY KEY,measurement_dimension text,mass_unit_code text);
                CREATE TABLE colors(id uuid PRIMARY KEY,name text,status text DEFAULT '使用',is_deleted boolean DEFAULT false);
                CREATE TABLE material_categories(id uuid PRIMARY KEY,code text,name text,parent_id uuid,level integer DEFAULT 0,
                  sort_order integer DEFAULT 0,is_deleted boolean DEFAULT false);
                CREATE TABLE goods(id uuid PRIMARY KEY,code text,name text,category_id uuid,color_id uuid,unit_id uuid,
                  version bigint DEFAULT 2,issue_method text DEFAULT 'ORDER',status text DEFAULT '使用',
                  is_deleted boolean DEFAULT false,auto_created boolean DEFAULT false);
                CREATE TABLE stock_balances(warehouse_id uuid,goods_id uuid,color_id uuid,qty numeric(18,4),
                  weight numeric(18,4),weight_estimated boolean DEFAULT false);
                CREATE FUNCTION fn_weight_unit_kg_factor(text) RETURNS numeric LANGUAGE sql IMMUTABLE
                  AS $$ SELECT CASE WHEN $1='KG' THEN 1::numeric WHEN $1='G' THEN 0.001::numeric END $$;
                """);
        try(var resource=getClass().getResourceAsStream("/db/migration/V613__operational_warehouse_leaf_identity.sql")) {
            String migration=new String(resource.readAllBytes(),StandardCharsets.UTF_8);
            db.execute(migration.substring(0,migration.indexOf("DO $migration$")));
        }
        db.update("INSERT INTO warehouses(id,code,name) VALUES (?,'LEAF','普通仓')",leaf);
        db.update("INSERT INTO warehouses(id,code,name,parent_id,is_line_side) VALUES (?,'BIN','本车间',?,true),(?,'OTHER','其它车间',?,true)",bin,leaf,foreignBin,leaf);
        db.update("INSERT INTO workshop_material_settings VALUES (?,true),(?,true)",bin,foreignBin);
        db.update("INSERT INTO units(id,name) VALUES (?,'千克'),(?,'个')",kg,pieces);
        db.update("INSERT INTO unit_measurement_profiles VALUES (?,'MASS','KG'),(?,'COUNT',NULL)",kg,pieces);
        user=mock(SecurityContextCurrentUser.class);
        as(StockCountRequestService.SUBMIT);
        workshop=mock(WorkshopStockCountPostingPort.class);
        when(workshop.canAccessWarehouse(bin)).thenReturn(true);
        // 批量 accessibleWarehouses 是接口默认方法(逐个调 canAccessWarehouse); mock
        // 不打这针会得到 Mockito 空集合默认答案，内料仓全部不可见。
        doCallRealMethod().when(workshop).accessibleWarehouses(any());
        service=new StockCountRequestService(new NamedParameterJdbcTemplate(db),user,workshop,
                mock(StockDocService.class),mock(DocNumberService.class),mock(BusinessEventPublisher.class),
                mock(TxSessionVars.class),new ObjectMapper(),mock(Validator.class));
    }

    @Test void treeContainsOnlyEligibleCategoriesAndAncestorsAndWorkshopKeepsMassMaterials() {
        UUID root=category("ROOT","全部物料",null),raw=category("RAW","原材料",root);
        UUID resin=category("RESIN","颗粒",raw),fasteners=category("FAST","紧固件",root);
        UUID empty=category("EMPTY","空分类",root),stubCategory=category("STUB","不明货品",root);
        UUID disabledCategory=category("OFF","无可用货品",root);
        UUID mass=goods("PP","PP 颗粒",resin,kg,null),count=goods("SCREW","螺丝",fasteners,pieces,null);
        UUID stub=goods("STUB-G","占位",stubCategory,kg,null),disabled=goods("OFF-G","停用",disabledCategory,kg,null);
        db.update("UPDATE goods SET auto_created=true WHERE id=?",stub);
        db.update("UPDATE goods SET status='禁用' WHERE id=?",disabled);
        var ordinary=service.candidateCategories(leaf);
        assertThat(flatten(ordinary).keySet()).containsExactlyInAnyOrder(root,raw,resin,fasteners);
        assertThat(flatten(ordinary).get(resin)).containsEntry("parentId",raw).containsEntry("name","颗粒");
        assertThat(ordinary).hasSize(1);
        assertThat(flatten(service.candidateCategories(bin)).keySet()).containsExactlyInAnyOrder(root,raw,resin);
        assertThat(service.candidates(bin,"",null,1,50).getItems()).extracting(r->r.get("goodsId")).containsExactly(mass);
        assertThat(service.candidates(leaf,"",List.of(stub,disabled),1,50).getTotal()).isZero();
        assertThat(service.candidateCategoryIds(bin,"螺丝")).isEmpty();
        assertThat(service.candidateCategoryIds(leaf,"螺丝")).containsExactly(fasteners);
        assertThat(flatten(ordinary).keySet()).doesNotContain(empty,stubCategory,disabledCategory);
    }

    @Test void parentSubtreeIntersectsIdsAndSearchWithoutCollapsingColorsAndPages() {
        UUID root=category("ROOT","物料",null),branch=category("A","塑料",root);
        UUID child=category("A1","颗粒",branch),sibling=category("B","金属",root);
        UUID black=color("黑"),white=color("白");
        UUID material=goods("PP","PP 颗粒",child,kg,black);
        UUID other=goods("FE","铁",sibling,kg,null);
        db.update("INSERT INTO stock_balances VALUES (?,?,?,4.1234,4.1234,false),(?,?,?,6,6,false)",leaf,material,black,leaf,material,white);
        var first=service.candidates(leaf,"",null,branch,1,1);
        var second=service.candidates(leaf,"",null,branch,2,1);
        assertThat(first.getTotal()).isEqualTo(2);
        assertThat(second.getTotalPages()).isEqualTo(2);
        assertThat(first.getItems()).hasSize(1);
        assertThat(second.getItems()).hasSize(1);
        assertThat(first.getItems().getFirst().get("colorId")).isNotEqualTo(second.getItems().getFirst().get("colorId"));
        assertThat(service.candidates(leaf,"黑",List.of(material),branch,1,50).getItems().getFirst())
                .containsEntry("goodsId",material).containsEntry("colorId",black)
                .containsEntry("categoryId",child).containsEntry("qty","4.1234");
        assertThat(service.candidates(leaf,"",List.of(other),branch,1,50).getTotal()).isZero();
        assertThat(service.candidates(leaf,"",null,UUID.randomUUID(),1,50).getTotal()).isZero();
        db.update("UPDATE material_categories SET is_deleted=true WHERE id=?",branch);
        assertThat(service.candidates(leaf,"",null,branch,1,50).getTotal()).isZero();
    }

    @Test void searchLocatesExactCategoriesUsingOnlySelectedWarehouseColorsAndActiveIdentities() {
        UUID root=category("ROOT","全部物料",null),resin=category("RESIN","颗粒",root);
        UUID rejected=category("BAD","停用候选",root);
        UUID material=goods("PP","聚丙烯",resin,kg,null),privateColor=color("别仓专用金色"),localColor=color("本仓蓝色");
        db.update("INSERT INTO stock_balances VALUES (?,?,?,1,1,false),(?,?,?,1,1,false)",foreignBin,material,privateColor,bin,material,localColor);
        assertThat(service.candidateCategoryIds(bin,"本仓蓝色")).containsExactly(resin);
        assertThat(service.candidateCategoryIds(bin,"别仓专用金色")).isEmpty();
        assertThat(service.candidateCategoryIds(bin,"  pp ")).containsExactly(resin);
        assertThat(service.candidateCategoryIds(bin," ")).isEmpty();
        UUID offColor=color("失效红色");
        goods("COLOR-OFF","颜色失效料",rejected,kg,offColor);
        db.update("UPDATE colors SET status='禁用' WHERE id=?",offColor);
        UUID deleted=goods("DELETED","已删料",rejected,kg,null);
        db.update("UPDATE goods SET is_deleted=true WHERE id=?",deleted);
        UUID wrongUnit=goods("UNIT-OFF","停用单位料",rejected,pieces,null);
        db.update("UPDATE units SET status='禁用' WHERE id=?",pieces);
        assertThat(flatten(service.candidateCategories(leaf)).keySet()).doesNotContain(rejected);
        assertThat(service.candidateCategoryIds(leaf,"失效")).isEmpty();
        assertThat(service.candidateCategoryIds(leaf,"停用单位")).isEmpty();
        assertThat(service.candidates(leaf,"",List.of(wrongUnit),1,50).getItems()).isEmpty();
    }

    @Test void uncategorizedBucketCoversNullAndDeletedCategoryWithoutChangingMasterIdentity() {
        UUID root=category("ROOT","物料",null),deleted=category("DELETED-CAT","旧分类",root);
        db.update("UPDATE material_categories SET is_deleted=true WHERE id=?",deleted);
        UUID noCategory=goods("NONE-CAT","无归属颗粒",null,kg,null);
        UUID deletedCategory=goods("OLD-CAT","旧分类颗粒",deleted,kg,null);
        var rows=service.candidates(bin,"",null,StockCountRequestService.UNCATEGORIZED_CATEGORY,1,50);
        assertThat(rows.getItems()).extracting(r->r.get("goodsId")).containsExactlyInAnyOrder(noCategory,deletedCategory);
        assertThat(rows.getItems()).allSatisfy(row->assertThat(row.get("categoryId")).isEqualTo(StockCountRequestService.UNCATEGORIZED_CATEGORY));
        var tree=service.candidateCategories(bin);
        assertThat(tree).hasSize(1);
        assertThat(tree.getFirst()).containsEntry("id",StockCountRequestService.UNCATEGORIZED_CATEGORY)
                .containsEntry("name","未分类").containsEntry("parentId",null);
        assertThat(service.candidateCategoryIds(bin,"颗粒")).containsExactly(StockCountRequestService.UNCATEGORIZED_CATEGORY);
        assertThat(service.candidates(bin,"",null,deleted,1,50).getItems()).isEmpty();
        assertThat(db.queryForObject("SELECT category_id FROM goods WHERE id=?",UUID.class,noCategory)).isNull();
        assertThat(db.queryForObject("SELECT category_id FROM goods WHERE id=?",UUID.class,deletedCategory)).isEqualTo(deleted);
        assertThat(db.queryForObject("SELECT count(*) FROM material_categories WHERE id=?",Integer.class,StockCountRequestService.UNCATEGORIZED_CATEGORY)).isZero();
    }

    @Test void treeAndSearchRetainGoodsDirectlyAssignedToTheRootAlongsideDescendants() {
        UUID root=category("ROOT","物料",null),child=category("CHILD","子类",root);
        UUID rootGoods=goods("ROOT-G","根直属料",root,kg,null),childGoods=goods("CHILD-G","子类料",child,kg,null);
        var tree=service.candidateCategories(bin);
        assertThat(tree).hasSize(1);
        assertThat(tree.getFirst()).containsEntry("id",root);
        assertThat(flatten(tree).keySet()).containsExactlyInAnyOrder(root,child);
        assertThat(service.candidates(bin,"",null,root,1,50).getItems()).extracting(row->row.get("goodsId"))
                .containsExactlyInAnyOrder(rootGoods,childGoods);
        assertThat(service.candidateCategoryIds(bin,"根直属料")).containsExactly(root);
        assertThat(flatten(tree).keySet()).doesNotContain(StockCountRequestService.UNCATEGORIZED_CATEGORY);
    }

    @Test void categoryAndSearchEndpointsRequireSubmitAndRespectWarehouseScopeEvenForEmptySearch() throws Exception {
        UUID root=category("ROOT","物料",null);goods("PP","PP",root,kg,null);
        as(StockCountRequestService.FINANCE);
        assertForbidden(()->service.candidateCategories(leaf));
        assertForbidden(()->service.candidateCategoryIds(leaf,""));
        assertForbidden(()->service.candidates(leaf,"",null,root,1,50));
        as(StockCountRequestService.SUBMIT);
        assertForbidden(()->service.candidateCategories(foreignBin));
        assertForbidden(()->service.candidateCategoryIds(foreignBin,""));
        assertForbidden(()->service.candidates(foreignBin,"",null,root,1,50));
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name) VALUES (?,'P','聚合仓')",parent);
        db.update("INSERT INTO warehouses(id,code,name,parent_id) VALUES (?,'C','子仓',?)",child,parent);
        assertForbidden(()->service.candidateCategories(parent));
        assertForbidden(()->service.candidateCategoryIds(parent,"PP"));
        assertThat(StockCountRequestController.class.getMethod("candidateCategories",UUID.class).getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('stock:count:submit')");
        assertThat(StockCountRequestController.class.getMethod("candidateCategoryIds",UUID.class,String.class).getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('stock:count:submit')");
    }

    private void as(String... permissions) {
        when(user.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"count-categories",
                Set.of(permissions),false,true,false)));
    }
    private UUID category(String code,String name,UUID parent) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO material_categories(id,code,name,parent_id) VALUES (?,?,?,?)",id,code,name,parent);return id;
    }
    private UUID goods(String code,String name,UUID category,UUID unit,UUID color) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO goods(id,code,name,category_id,unit_id,color_id) VALUES (?,?,?,?,?,?)",id,code,name,category,unit,color);return id;
    }
    private UUID color(String name) { UUID id=UUID.randomUUID();db.update("INSERT INTO colors(id,name) VALUES (?,?)",id,name);return id; }
    private static void assertForbidden(Runnable operation) {
        assertThatThrownBy(operation::run).isInstanceOf(ApiException.class).satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
    @SuppressWarnings("unchecked")
    private static Map<UUID,Map<String,Object>> flatten(List<Map<String,Object>> nodes) {
        Map<UUID,Map<String,Object>> result=new LinkedHashMap<>();
        for(var node:nodes) { result.put((UUID)node.get("id"),node);result.putAll(flatten((List<Map<String,Object>>)node.get("children"))); }
        return result;
    }
}
