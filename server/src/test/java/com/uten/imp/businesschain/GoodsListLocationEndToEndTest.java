package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsPageLocation;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.master.materialcategory.dto.MaterialCategorySaveRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Current services against the fully migrated schema; no private schema or disabled guards. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@Import(ProductionJdbcMeasurement.Configuration.class)
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=true",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=goods-locator-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class GoodsListLocationEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        String url=System.getenv("UTEN_GOODS_LOCATOR_TEST_JDBC_URL");
        if(url==null||url.isBlank()) {FullChainEndToEndTest.registerDataSource(registry);return;}
        // Optional local acceleration accepts only a deliberately named private test clone.
        if(!url.matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/uten_goods_locator_[a-z0-9_]+"))
            throw new IllegalArgumentException("The locator fixture requires its own named test clone");
        registry.add("spring.datasource.url",()->url);
        registry.add("spring.datasource.username",()->System.getenv("UTEN_GOODS_LOCATOR_TEST_DB_USER"));
        registry.add("spring.datasource.password",()->System.getenv("UTEN_GOODS_LOCATOR_TEST_DB_PASSWORD"));
        String storage=java.nio.file.Path.of(System.getProperty("java.io.tmpdir"),"uten-goods-locator-"+UUID.randomUUID()).toString();
        registry.add("uten.storage.local-dir",()->storage);
    }

    @Autowired GoodsService goods;
    @Autowired MaterialCategoryService categories;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired AutowireCapableBeanFactory beans;
    FullChainEndToEndTest fixture;
    FullChainEndToEndTest.World world;
    String tag;

    @BeforeEach void before() {
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        tag=UUID.randomUUID().toString().replace("-","").substring(0,7).toUpperCase();
        world=fixture.seedWorld("goods-locate-"+tag);fixture.loginAs(world.superAdminUserId());
    }
    @AfterEach void after(){ProductionJdbcMeasurement.end();SecurityContextHolder.clearContext();}

    @Test void oneHundredFiftySevenRowsUseOneBomProjectionPerPageAndAnInheritedPrefixCopyLocatesOnTheFirstPage() {
        String prefix="L"+tag.substring(0,6);
        UUID root=category(null,"定位继承根"+tag,prefix),leaf=category(root,"塑胶件"+tag,null);
        List<UUID> original=new ArrayList<>();
        for(int index=0;index<157;index++)original.add(seed(leaf,"ZX"+tag+String.format("%03d",index),"原货品"+index,null));
        UUID partCategory=category(null,"组件"+tag,null);
        UUID activePart=seed(partCategory,"CP"+tag,"在用组件",null);
        UUID disabledPart=seed(partCategory,"DP"+tag,"停用组件",null);
        edge(original.get(0),activePart,false);edge(original.get(1),activePart,true);
        UUID retiredEdge=edge(original.get(2),disabledPart,false);
        db.update("UPDATE goods SET status='禁用' WHERE id=?",disabledPart);
        GoodsQueryFilter query=filter(Map.of("categoryId",leaf));
        var small=ProductionJdbcMeasurement.begin();goods.list(query,1,1,null,null);ProductionJdbcMeasurement.end();
        var large=ProductionJdbcMeasurement.begin();var page=goods.list(query,1,200,null,null);ProductionJdbcMeasurement.end();
        assertEquals(100,page.getItems().size());assertEquals(157,page.getTotal());
        assertEquals(1,bomReads(small));assertEquals(1,bomReads(large),"BOM presence must be one batch read, not one read per goods row");
        assertTrue(page.getItems().get(0).isHasBom());
        assertFalse(page.getItems().get(1).isHasBom(),"A deleted BOM edge is not a current BOM");
        assertFalse(page.getItems().get(2).isHasBom(),"A retired disabled-component edge is historical, not a current BOM");
        assertEquals(1,db.queryForObject("""
                SELECT count(*) FROM goods_bom_items
                WHERE id=? AND goods_id=? AND component_goods_id=? AND is_deleted
                  AND deleted_at IS NOT NULL AND learning_released_at IS NOT NULL
                  AND retirement_reason='COMPONENT_DISABLED' AND retirement_resolved_at IS NULL
                """,Integer.class,retiredEdge,original.get(2),disabledPart),
                "Retirement must preserve the original BOM edge and its history");
        assertEquals(1,db.queryForObject("""
                SELECT count(*) FROM business_outbox
                WHERE event_type='GOODS_BOM_UPDATED' AND aggregate_type='GOODS_BOM'
                  AND aggregate_id=? AND payload->>'reason'='COMPONENT_DISABLED'
                """,Integer.class,original.get(2)));
        assertTrue(page.getItems().subList(3,100).stream().noneMatch(GoodsListItem::isHasBom));
        var tailSample=ProductionJdbcMeasurement.begin();var tail=goods.list(query,2,100,null,null);ProductionJdbcMeasurement.end();
        assertEquals(57,tail.getItems().size());assertEquals(1,bomReads(tailSample));
        assertTrue(tail.getItems().stream().noneMatch(GoodsListItem::isHasBom));
        var request=new GoodsSaveRequest();request.setCategoryId(leaf);request.setName("副本"+tag);request.setUnitId(world.unitId());
        var copy=goods.create(request);
        assertEquals(prefix+"01",copy.getCode());
        var located=goods.locate(query,copy.getId(),100,null,null);
        assertEquals(new GoodsPageLocation(true,1,0),located,"A generated inherited prefix can sort before all 157 old codes");
        assertEquals(copy.getId(),goods.list(query,located.page(),100,null,null).getItems().get(located.rowIndex()).getId());
        for(UUID id:List.of(original.get(0),original.get(99),original.get(156)))assertLocation(query,id,100,null,null);
        db.update("UPDATE goods SET status='禁用' WHERE id=?",original.get(0));
        var includingDisabled=filter(Map.of("categoryId",leaf,"excludeDisabled",false));
        assertTrue(goods.list(includingDisabled,1,100,null,null).getItems().stream()
                .filter(row->row.getId().equals(original.get(0))).findFirst().orElseThrow().isHasBom(),
                "A disabled parent retains its own active recipe when disabled goods are included");
    }

    @ParameterizedTest @CsvSource({"code,asc","code,desc","price,asc","price,desc"})
    void pageLocationMatchesRealPagingWithNullPricesAndStableSameValueIdentities(String sort,String order) {
        UUID category=category(null,"排序"+tag,null);
        List<GoodsListItem> seeded=new ArrayList<>();
        for(int index=0;index<13;index++) {
            UUID id=seed(category,"SORT"+tag+String.format("%02d",index),"同价货品"+index,index%4==0?null:new BigDecimal(index%3));
            assertNotNull(id);
        }
        var query=filter(Map.of("categoryId",category));
        seeded.addAll(goods.list(query,1,100,"code","asc").getItems());
        Comparator<GoodsListItem> comparator="code".equals(sort)
                ?Comparator.comparing(GoodsListItem::getCode)
                :Comparator.comparing(GoodsListItem::getPrice,Comparator.nullsLast(BigDecimal::compareTo));
        comparator=comparator.thenComparing(row->row.getId().toString());
        if("desc".equals(order))comparator=comparator.reversed();
        var expected=seeded.stream().sorted(comparator).map(GoodsListItem::getId).toList();
        assertEquals(expected,goods.list(query,1,100,sort,order).getItems().stream().map(GoodsListItem::getId).toList());
        for(UUID id:expected)assertLocation(query,id,4,sort,order);
    }

    @Test void keywordRanksStayAheadOfRequestedSortAndExcludedFiltersReturnNotFound() {
        String word="NEEDLE"+tag;
        UUID root=category(null,"关键词范围"+tag,null),matchedCategory=category(root,word+"类",null),other=category(root,"其他"+tag,null);
        UUID exactName=seed(other,"ZZ"+tag,word,new BigDecimal("30"));
        seed(other,word,"编号准确命中",BigDecimal.ONE);
        seed(matchedCategory,"AA"+tag,"分类命中",new BigDecimal("20"));
        seed(other,"BB"+tag,word+"接线式",new BigDecimal("10"));
        UUID notes=seed(other,"CC"+tag,"仅备注命中",new BigDecimal("40"));
        db.update("UPDATE goods SET paper=? WHERE id=?",word,notes);
        for(String sort:List.of("code","price"))for(String order:List.of("asc","desc")) {
            var query=filter(Map.of("categoryRootIds",Set.of(root),"keyword",word,"includeRelated",true));
            var actual=goods.list(query,1,100,sort,order).getItems();
            assertEquals(5,actual.size());assertEquals(exactName,actual.getFirst().getId());
            for(var row:actual)assertLocation(query,row.getId(),2,sort,order);
        }
        var noRelated=filter(Map.of("categoryRootIds",Set.of(root),"keyword",word,"includeRelated",false));
        assertFalse(goods.locate(noRelated,notes,2,"code","asc").found());
        var excluded=filter(Map.of("categoryId",other,"columnSearch",Map.of("name","不会命中")));
        assertEquals(new GoodsPageLocation(false,1,0),goods.locate(excluded,exactName,2,null,null));
        var disabled=seed(other,"DIS"+tag,"停用筛选",null);db.update("UPDATE goods SET status='禁用' WHERE id=?",disabled);
        assertFalse(goods.locate(filter(Map.of("categoryId",other)),disabled,2,null,null).found());
        assertFalse(goods.locate(filter(Map.of("categoryId",matchedCategory)),exactName,2,null,null).found());
    }

    @Test void objectVisibilityIsAppliedBeforeListBomProjectionAndLocationCounting() {
        UUID category=category(null,"归属"+tag,null);
        UUID own=seed(category,"OWN"+tag,"本人货品",null),publicRow=seed(category,"PUB"+tag,"公共货品",null),hidden=seed(category,"HID"+tag,"他人货品",null);
        var other=fixture.seedWorld("other-owner-"+tag);
        db.update("UPDATE goods SET owner_employee_id=? WHERE id=?",world.employeeId(),own);
        db.update("UPDATE goods SET owner_employee_id=? WHERE id=?",other.employeeId(),hidden);
        var actor=new AuthUser(world.superAdminUserId(),world.employeeId(),"locator-owner",Set.of("goods:view"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
        var query=filter(Map.of("categoryId",category));
        assertEquals(Set.of(own,publicRow),Set.copyOf(goods.list(query,1,100,null,null).getItems().stream().map(GoodsListItem::getId).toList()));
        assertFalse(goods.locate(query,hidden,1,null,null).found());
        assertLocation(query,own,1,null,null);assertLocation(query,publicRow,1,null,null);
    }

    @Test void nullAndDuplicateCodesRemainImpossibleUnderTheAuthoritativeIdentifierGuards() {
        UUID category=category(null,"编号约束"+tag,null);
        UUID first=seed(category,"UNIQUEA"+tag,"甲",null),second=seed(category,"UNIQUEB"+tag,"乙",null);
        assertThrows(DataIntegrityViolationException.class,()->db.update("UPDATE goods SET code=NULL WHERE id=?",first));
        assertThrows(DataIntegrityViolationException.class,()->db.update("UPDATE goods SET code=? WHERE id=?","UNIQUEA"+tag,second));
        assertEquals("UNIQUEB"+tag,db.queryForObject("SELECT code FROM goods WHERE id=?",String.class,second));
    }

    private void assertLocation(GoodsQueryFilter filter,UUID id,int size,String sort,String order) {
        var first=goods.list(filter,1,100,sort,order);
        var all=new ArrayList<>(first.getItems());
        for(int page=2;page<=first.getTotalPages();page++)all.addAll(goods.list(filter,page,100,sort,order).getItems());
        int index=all.stream().map(GoodsListItem::getId).toList().indexOf(id);assertTrue(index>=0);
        var expected=new GoodsPageLocation(true,index/size+1,index%size);
        assertEquals(expected,goods.locate(filter,id,size,sort,order),sort+" "+order+" "+id);
        assertEquals(id,goods.list(filter,expected.page(),size,sort,order).getItems().get(expected.rowIndex()).getId());
    }
    private GoodsQueryFilter filter(Map<String,Object> fields) {
        Map<String,Object> values=new HashMap<>(Map.of("nullFields",Set.of(),"columnSearch",Map.of(),"excludeDisabled",true,"excludeStub",true));
        values.putAll(fields);return json.convertValue(values,GoodsQueryFilter.class);
    }
    private UUID category(UUID parent,String name,String prefix) {
        var body=new MaterialCategorySaveRequest();body.setParentId(parent);body.setName(name);body.setCodePrefix(prefix);
        return categories.create(body).getId();
    }
    private UUID seed(UUID category,String code,String name,BigDecimal price) {
        UUID id=UUID.randomUUID();
        db.update("""
                INSERT INTO goods(id,category_id,code,name,unit_id,price,status,auto_created,code_sequence)
                VALUES(?,?,?,?,?,?,'使用',false,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """,id,category,code,name,world.unitId(),price);return id;
    }
    private UUID edge(UUID parent,UUID component,boolean deleted) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,sort_order) VALUES(?,?,?,1,1)",id,parent,component);
        if(deleted)db.update("UPDATE goods_bom_items SET is_deleted=true,deleted_at=now() WHERE goods_id=? AND component_goods_id=?",parent,component);
        return id;
    }
    private long bomReads(ProductionJdbcMeasurement.Sample sample) {
        return sample.fingerprints.entrySet().stream().filter(entry->"read.goods_bom_items".equals(sample.labelsByFingerprint.get(entry.getKey())))
                .mapToLong(Map.Entry::getValue).sum();
    }
}
