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
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real PostgreSQL candidate/category SQL with the operational-warehouse function; never uses the business database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockCountCandidateCategoriesPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
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
                CREATE TABLE colors(id uuid PRIMARY KEY,name text,status text DEFAULT '使用',is_deleted boolean DEFAULT false,remark text);
                CREATE TABLE material_categories(id uuid PRIMARY KEY,code text,name text,parent_id uuid,level integer DEFAULT 0,
                  sort_order integer DEFAULT 0,is_deleted boolean DEFAULT false);
                CREATE TABLE goods(id uuid PRIMARY KEY,code text,name text,category_id uuid,color_id uuid,unit_id uuid,
                  code_sequence bigint NOT NULL CHECK(code_sequence>0),
                  version bigint DEFAULT 2,issue_method text DEFAULT 'ORDER',status text DEFAULT '使用',
                  is_deleted boolean DEFAULT false,auto_created boolean DEFAULT false,
                  stock_place text,model text,spec text,c_number text,series text,material text,name_en text,owning_warehouse_id uuid, client_goods_name text);
                CREATE TABLE stock_balances(warehouse_id uuid,goods_id uuid,color_id uuid,qty numeric(18,4),
                  weight numeric(18,4),weight_estimated boolean DEFAULT false);
                CREATE FUNCTION fn_weight_unit_kg_factor(text) RETURNS numeric LANGUAGE sql IMMUTABLE
                  AS $$ SELECT CASE WHEN $1='KG' THEN 1::numeric WHEN $1='G' THEN 0.001::numeric END $$;
                """);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentColumns(db,"stock_measurement_holds");
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
                mock(TxSessionVars.class),new ObjectMapper(),mock(Validator.class),
                mock(com.uten.imp.application.concurrency.FulfillmentMutationLocks.class),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
    }

    @Test void originalMeasurementHoldIsNotAnOrdinaryDifferenceCountCandidateAfterMasterUnitCompletion() {
        UUID category=category("HELD","待核原账",null);
        UUID held=goods("HELD-STOCK","当前主档已有单位但原数量仍待核",category,kg,null);
        UUID nativeKnown=goods("KNOWN-STOCK","正常已知单位库存",category,kg,null);
        db.update("INSERT INTO stock_balances VALUES (?,?,NULL,9,18,true),(?,?,NULL,4,4,false)",leaf,held,leaf,nativeKnown);
        db.update("INSERT INTO stock_measurement_holds(warehouse_id,goods_id,color_id) VALUES (?,?,NULL)",leaf,held);
        assertThat(service.candidates(leaf,"",null,1,50).getItems()).extracting(row->row.get("goodsId"))
                .contains(nativeKnown).doesNotContain(held);
        assertThat(db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,leaf,held))
                .isEqualByComparingTo("9");
        assertThat(service.candidateCategories(leaf)).hasSize(1);
    }

    @Test void treeKeepsDisabledGoodsCountableAndPrunesStubOnlyCategories() {
        UUID root=category("ROOT","全部物料",null),raw=category("RAW","原材料",root);
        UUID resin=category("RESIN","颗粒",raw),fasteners=category("FAST","紧固件",root);
        UUID empty=category("EMPTY","空分类",root),stubCategory=category("STUB","不明货品",root);
        UUID retired=category("RETIRED","老料",root);
        UUID mass=goods("PP","PP 颗粒",resin,kg,null);
        goods("SCREW","螺丝",fasteners,pieces,null);
        // 停用货品且带主档默认色: 两个历史根因一起锁——禁用可盘, 候选行仍是无色(不是默认色)。
        UUID stub=goods("STUB-G","占位",stubCategory,kg,null),disabled=goods("OFF-G","停用",retired,kg,color("米白"));
        db.update("UPDATE goods SET auto_created=true WHERE id=?",stub);
        // 「禁用」不挡盘点: 停用货品照常入候选/分类树, 只有删除与 auto_created 占位被排除。
        db.update("UPDATE goods SET status='禁用' WHERE id=?",disabled);
        var ordinary=service.candidateCategories(leaf);
        assertThat(flatten(ordinary).keySet()).containsExactlyInAnyOrder(root,raw,resin,fasteners,retired);
        assertThat(flatten(ordinary).get(resin)).containsEntry("parentId",raw).containsEntry("name","颗粒");
        assertThat(ordinary).hasSize(1);
        assertThat(flatten(service.candidateCategories(bin)).keySet()).containsExactlyInAnyOrder(root,raw,resin,retired);
        assertThat(service.candidates(bin,"",null,1,50).getItems()).extracting(r->r.get("goodsId"))
                .containsExactlyInAnyOrder(mass,disabled);
        assertThat(service.candidates(leaf,"",List.of(stub),1,50).getTotal()).isZero();
        // 零余额货品出一行无色候选(与即时库存表的无色行同键), 不是货品主档默认色。
        assertThat(service.candidates(leaf,"",List.of(disabled),1,50).getTotal()).isEqualTo(1);
        assertThat(service.candidates(leaf,"",List.of(disabled),1,50).getItems())
                .extracting(r->r.get("colorId")).containsOnlyNulls();
        // 盘点页「有库存」段: stockedOnly 把零余额行滤掉, 只留本仓有账面数量的行。
        assertThat(service.candidates(leaf,"",null,null,true,false,1,50).getItems())
                .extracting(r->r.get("goodsId")).doesNotContain(disabled);
        db.update("INSERT INTO stock_balances VALUES (?,?,NULL,3,NULL,false)",leaf,disabled);
        assertThat(service.candidates(leaf,"",null,null,true,false,1,50).getItems())
                .extracting(r->r.get("goodsId")).contains(disabled);
        assertThat(service.candidateCategoryIds(bin,"螺丝")).isEmpty();
        assertThat(service.candidateCategoryIds(leaf,"螺丝")).containsExactly(fasteners);
        assertThat(flatten(ordinary).keySet()).doesNotContain(empty,stubCategory);
    }

    @Test void sheetScopesRowsToWarehouseOwnershipPlusBalancesWhilePickerSeesAll() {
        UUID root=category("ROOT","物料",null);
        // 「别仓」用测试内自建普通仓：不碰 foreignBin(它承担"不可访问仓 403"的既有断言)。
        UUID other=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name) VALUES (?,'OTHER','别仓')",other);
        UUID owned=goods("OWN","本仓管辖料",root,kg,null);
        db.update("UPDATE goods SET owning_warehouse_id=? WHERE id=?",leaf,owned);
        UUID foreign=goods("FOREIGN","别仓管辖料",root,kg,null);
        db.update("UPDATE goods SET owning_warehouse_id=? WHERE id=?",other,foreign);
        UUID stocked=goods("STOCKED","在库有余额料",root,kg,null);
        db.update("INSERT INTO stock_balances VALUES (?,?,NULL,2,2,false)",leaf,stocked);
        // 盘点单口径(2026-10-08): 换仓行数不同——只列 主档归属本仓 ∪ 本仓有余额。
        assertThat(service.candidates(leaf,"",null,null,false,true,1,50).getItems())
                .extracting(r->r.get("goodsId")).containsExactlyInAnyOrder(owned,stocked);
        assertThat(service.candidates(other,"",null,null,false,true,1,50).getItems())
                .extracting(r->r.get("goodsId")).containsExactly(foreign);
        // 全库候选(添加物料选择器)不受 sheet 影响, 任何货品都能盘盈加入。
        assertThat(service.candidates(leaf,"",null,1,50).getItems())
                .extracting(r->r.get("goodsId")).containsExactlyInAnyOrder(owned,foreign,stocked);
        // 分类树同样支持 sheet 口径(该仓有行的分类才出现)。
        assertThat(flatten(service.candidateCategories(leaf,true)).keySet()).containsExactly(root);
        assertThat(service.candidateCategories(other,true)).hasSize(1);
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

    @Test void searchUsesSelectedWarehouseColorsWhileDisabledIdentitiesStayCountable() {
        UUID root=category("ROOT","全部物料",null),resin=category("RESIN","颗粒",root);
        UUID rejected=category("BAD","停用候选",root);
        UUID material=goods("PP","聚丙烯",resin,kg,null),privateColor=color("别仓专用金色"),localColor=color("本仓蓝色");
        db.update("INSERT INTO stock_balances VALUES (?,?,?,1,1,false),(?,?,?,1,1,false)",foreignBin,material,privateColor,bin,material,localColor);
        assertThat(service.candidateCategoryIds(bin,"本仓蓝色")).containsExactly(resin);
        assertThat(service.candidateCategoryIds(bin,"别仓专用金色")).isEmpty();
        assertThat(service.candidateCategoryIds(bin,"  pp ")).containsExactly(resin);
        assertThat(service.candidateCategoryIds(bin," ")).isEmpty();
        // 禁用颜色/单位的货品照常可盘(与普通库存单同口径, 只挡删除); 已删货品仍排除。
        UUID offColor=color("失效红色");
        goods("COLOR-OFF","颜色失效料",rejected,kg,offColor);
        db.update("UPDATE colors SET status='禁用' WHERE id=?",offColor);
        UUID deleted=goods("DELETED","已删料",rejected,kg,null);
        db.update("UPDATE goods SET is_deleted=true WHERE id=?",deleted);
        UUID wrongUnit=goods("UNIT-OFF","停用单位料",rejected,pieces,null);
        db.update("UPDATE units SET status='禁用' WHERE id=?",pieces);
        assertThat(flatten(service.candidateCategories(leaf)).keySet()).contains(rejected);
        assertThat(service.candidateCategoryIds(leaf,"失效")).containsExactly(rejected);
        assertThat(service.candidateCategoryIds(leaf,"停用单位")).containsExactly(rejected);
        assertThat(service.candidates(leaf,"",List.of(wrongUnit),1,50).getItems()).hasSize(1);
        assertThat(service.candidates(leaf,"",List.of(deleted),1,50).getTotal()).isZero();
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
        assertThat(StockCountRequestController.class.getMethod("candidateCategories",UUID.class,boolean.class).getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('stock:count:submit')");
        assertThat(StockCountRequestController.class.getMethod("candidateCategoryIds",UUID.class,String.class).getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('stock:count:submit')");
    }

    @Test void categoryWordsMatchAllEligibleDescendantsAndRankBeforeIncidentalContainsWithStablePaging() {
        UUID root=category("ROOT","物料",null),screws=category("SCREWS","螺丝类",root),coated=category("COATED","镀锌件",screws);
        UUID other=category("OTHER","轨道螺丝",root);
        UUID exact=goods("螺丝","完整编号",root,kg,null);
        UUID branch=goods("Z-3","圆头件",coated,kg,null);
        UUID approximate=goods("A-1","其它件",other,kg,null);
        db.update("UPDATE goods SET model='M3_20%' WHERE id IN (?,?)",branch,approximate);
        UUID lookalike=goods("Z-4","圆头件",coated,kg,null);
        db.update("UPDATE goods SET model='M3X20A' WHERE id=?",lookalike);
        assertThat(service.candidates(bin,"螺丝",null,root,1,1).getItems().getFirst()).containsEntry("goodsId",exact);
        var first=service.candidates(bin,"螺丝 M3_20%",null,root,1,1);
        var second=service.candidates(bin,"螺丝 M3_20%",null,root,2,1);
        assertThat(first.getTotal()).isEqualTo(2);
        assertThat(first.getItems().getFirst()).containsEntry("goodsId",branch);
        assertThat(second.getItems().getFirst()).containsEntry("goodsId",approximate);
        assertThat(service.candidateCategoryIds(bin,"螺丝 M3_20%")).containsExactly(coated);
        assertThat(service.candidateCategoryIds(bin,"螺丝 M3_20%",null,false,false,true)).containsExactly(coated,other);
        db.update("UPDATE goods SET auto_created=true WHERE id=?",branch);
        assertThat(service.candidates(bin,"螺丝 M3_20%",null,root,1,50).getItems())
                .extracting(row->row.get("goodsId")).containsExactly(approximate);
    }

    @Test void relocationUsesTheBestRecordRankBeforeCategoryUuidOrder(){
        UUID a=category("A","分区甲",null),b=category("B","分区乙",null);
        UUID exactCategory=a.toString().compareTo(b.toString())>0?a:b;
        UUID approximateCategory=exactCategory.equals(a)?b:a;
        UUID exact=goods("PART-001","精确零件",exactCategory,kg,null);
        UUID approximate=goods("OTHER","普通件",approximateCategory,kg,null);
        db.update("UPDATE goods SET model='供PART-001使用' WHERE id=?",approximate);
        assertThat(service.candidateCategoryIds(bin,"PART-001")).containsExactly(exactCategory,approximateCategory);
        assertThat(service.candidates(bin,"PART-001",null,1,1).getItems().getFirst()).containsEntry("goodsId",exact);
    }

    @Test void primaryAndExpandedSearchPreserveInventoryColorKeysAndExplicitCategoryScope() {
        UUID root=category("ROOT","物料",null),screws=category("SCREWS","螺丝类",root);
        UUID coated=category("COATED","镀锌件",screws),sockets=category("SOCKETS","插座",root);
        UUID black=color("黑"),white=color("白");
        UUID real=goods("Z-SCREW","M3x20",coated,kg,null);
        UUID feature=goods("A-SOCKET","电话插座（螺丝接线式）",sockets,kg,null);
        db.update("INSERT INTO stock_balances VALUES (?,?,?,3.125,3.125,false),(?,?,?,4.5,4.5,false)",bin,real,black,bin,real,white);
        var main=service.candidates(bin,"螺丝",null,null,false,false,1,1,false);
        assertThat(main.getTotal()).isEqualTo(2);
        assertThat(main.getItems().getFirst()).containsEntry("goodsId",real).containsEntry("searchMatchKind","PRIMARY");
        var expanded=service.candidates(bin,"螺丝",null,null,false,false,1,10,true);
        assertThat(expanded.getTotal()).isEqualTo(3);
        assertThat(expanded.getItems()).extracting(row->row.get("goodsId")).containsExactly(real,real,feature);
        assertThat(expanded.getItems().subList(0,2)).extracting(row->row.get("colorId")).containsExactlyInAnyOrder(black,white);
        assertThat(expanded.getItems().getLast()).containsEntry("searchMatchKind","RELATED");
        assertThat(service.candidateCategoryIds(bin,"螺丝",null,false,false,false)).containsExactly(coated);
        assertThat(service.candidateCategoryIds(bin,"螺丝",null,false,false,true)).containsExactly(coated,sockets);
        assertThat(service.candidates(bin,"螺丝",null,sockets,false,false,1,10,false).getItems())
                .singleElement().satisfies(row->assertThat(row).containsEntry("goodsId",feature).containsEntry("searchMatchKind","PRIMARY"));
        assertThat(service.candidateCategoryIds(bin,"螺丝",sockets,false,false,false)).containsExactly(sockets);
        assertThat(service.candidateCategoryIds(bin,"螺丝",null,true,false,true)).containsExactly(coated);
        assertThat(service.candidates(bin,"",null,null,false,false,1,10,false).getItems())
                .allSatisfy(row->assertThat(row).doesNotContainKeys("searchRank","searchMatchKind"));
    }

    private void as(String... permissions) {
        when(user.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"count-categories",
                Set.of(permissions),false,true,false)));
    }
    private UUID category(String code,String name,UUID parent) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO material_categories(id,code,name,parent_id) VALUES (?,?,?,?)",id,code,name,parent);return id;
    }
    private UUID goods(String code,String name,UUID category,UUID unit,UUID color) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO goods(id,code,name,category_id,unit_id,color_id,code_sequence) VALUES (?,?,?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",id,code,name,category,unit,color);return id;
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
