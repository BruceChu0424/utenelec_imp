package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 「BOM 学习记录」的两条查询在真实迁移后的视图上跑(ADR-129)：组装边读 v_goods_bom_item_usage，
 * BOM 外的料读 v_goods_bom_actual_usage，两种行经同一个 BomItemUsage 映射、输出同一组接口字段；
 * 不良数、实产单耗与不良率也都是视图的结果(本轮窗口，减过重新学习基线)。
 * EntityManager 只是把服务自己的 SQL 原样交给 JDBC 执行，不改写查询。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsBomLearningQueryPostgresTest {
    static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
    static String actualUsageView,usageView;
    Connection db;
    UUID unit;

    @BeforeAll static void migrate()throws Exception {
        DATABASE.start();
        var migration=Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .locations("classpath:db/migration").load();
        migration.migrate();
        try(Connection plain=connection();var statement=plain.createStatement();
            var rows=statement.executeQuery("SELECT pg_get_viewdef('public.v_goods_bom_actual_usage'::regclass,true),"
                    +"pg_get_viewdef('public.v_goods_bom_item_usage'::regclass,true)")) {
            assertTrue(rows.next());actualUsageView=rows.getString(1);usageView=rows.getString(2);
        }
    }
    @AfterAll static void stop(){DATABASE.stop();}
    @AfterEach void close()throws Exception {db.close();}
    @BeforeEach void fixture()throws Exception {
        db=connection();
        String schema="bom_query_"+UUID.randomUUID().toString().replace("-","");
        sql("CREATE SCHEMA "+schema);sql("SET search_path TO "+schema+",public");
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db,"goods","units");
        MigratedProjectionSchema.copyConstrainedTablesFromMigratedCatalog(db,"goods_bom_items",
                "goods_bom_learning_profiles","goods_bom_actual_usages");
        sql("CREATE VIEW v_goods_bom_actual_usage AS "+actualUsageView);
        sql("CREATE VIEW v_goods_bom_item_usage AS "+usageView);
        unit=unit("个");
    }

    @Test void bomEdgesAndOffBomMaterialsShareTheUsageViewsAndOneJsonShape()throws Exception {
        UUID parent=goods("P01"),edgeComponent=goods("A01"),released=goods("B01"),unitChanged=goods("C01"),relearned=goods("D01");
        UUID edge=UUID.randomUUID();
        sql("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,0.3)",edge,parent,edgeComponent);
        // 人删过的学习边：BOM 外那一行标「删过不再自动加回」。
        sql("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,is_deleted,deleted_at,learning_released_at)"
                +" VALUES(?,?,?,1,true,now(),now())",UUID.randomUUID(),parent,released);
        sql("INSERT INTO goods_bom_learning_profiles(goods_id,output_unit_id,total_output_qty,total_defect_qty,sample_count)"
                +" VALUES(?,?,400,100,2)",parent,unit);
        usage(parent,edgeComponent,unit,"110","400","100",2,false);
        usage(parent,released,unit,"20","400","100",2,false);
        usage(parent,unitChanged,unit("箱"),"30","400","0",2,false);
        usage(parent,relearned,unit,"50","400","100",2,true);

        var summary=service().summary(parent);

        amount("400",summary.profile().totalOutputQty());amount("100",summary.profile().totalDefectQty());
        assertEquals(2,summary.profile().sampleCount());
        assertFalse(summary.canRelearn());
        assertEquals(List.of(edgeComponent,released,unitChanged,relearned),
                summary.components().stream().map(GoodsBomLearningQueryService.Component::componentGoodsId).toList());
        var inBom=summary.components().get(0);
        assertTrue(inBom.inBom());assertEquals(edge,inBom.bomItemId());amount("0.3",inBom.designQty());
        amount("0.275",inBom.usage().actualQty());amount("0.275",inBom.usage().actualPerUnitQty());
        assertEquals("ACTUAL",inBom.usage().actualStatus());assertEquals("ACTUAL",inBom.usage().usageBasis());
        amount("0.275",inBom.usage().effectiveQty());assertEquals(2,inBom.usage().actualSampleCount());
        amount("110",inBom.usage().actualNetQty());amount("400",inBom.usage().actualOutputQty());
        // 良品 400、不良 100：实产单耗 = 110 / 500，不良率 = 100 / 500；真实使用数量仍按良品。
        amount("100",inBom.usage().actualDefectQty());amount("0.22",inBom.usage().actualPerProducedQty());
        amount("0.2",inBom.usage().actualDefectRate());

        var offBom=summary.components().get(1);
        assertFalse(offBom.inBom());assertTrue(offBom.released());assertNull(offBom.bomItemId());assertNull(offBom.designQty());
        amount("0.05",offBom.usage().actualQty());amount("0.05",offBom.usage().actualPerUnitQty());
        assertEquals("ACTUAL",offBom.usage().actualStatus());
        assertNull(offBom.usage().effectiveQty());assertNull(offBom.usage().usageBasis());assertFalse(offBom.usage().systemLearned());
        assertEquals(2,offBom.usage().actualSampleCount());amount("20",offBom.usage().actualNetQty());
        // BOM 外的料按每父件基本单位：20 / (400 + 100)。
        amount("100",offBom.usage().actualDefectQty());amount("0.04",offBom.usage().actualPerProducedQty());
        amount("0.2",offBom.usage().actualDefectRate());

        // 父件基本单位变了：状态与空值都来自视图，不再给一个无效的平均值。
        var changed=summary.components().get(2).usage();
        assertEquals("OUTPUT_UNIT_CHANGED",changed.actualStatus());assertNull(changed.actualQty());assertNull(changed.actualPerUnitQty());
        // 不良率不依赖父件单位；实产单耗与真实使用数量同一条件，单位变了就不给。
        assertNull(changed.actualPerProducedQty());amount("0",changed.actualDefectQty());amount("0",changed.actualDefectRate());
        assertFalse(summary.components().get(2).released());

        // 重新学习后还没有新数据：窗口是视图减过基线的数，没有数据。
        var fresh=summary.components().get(3).usage();
        assertEquals("NO_DATA",fresh.actualStatus());assertNull(fresh.actualQty());
        assertEquals(0,fresh.actualSampleCount());amount("0",fresh.actualNetQty());amount("0",fresh.actualOutputQty());
        // 不良也按基线扣掉：本轮没有产出，不良数 0，不良率与实产单耗都没有。
        amount("0",fresh.actualDefectQty());assertNull(fresh.actualDefectRate());assertNull(fresh.actualPerProducedQty());
        assertNotNull(fresh.relearnedAt());

        // 接口：组装边与 BOM 外的料同一组字段，真实使用数量平铺，不嵌套。
        JsonNode json=new ObjectMapper().findAndRegisterModules().valueToTree(summary);
        Set<String> edgeKeys=keys(json.get("components").get(0));
        for(JsonNode component:json.get("components"))assertEquals(edgeKeys,keys(component));
        for(String key:List.of("actualQty","actualPerUnitQty","actualStatus","effectiveQty","usageBasis","actualSampleCount",
                "actualOutputQty","actualNetQty","actualUpdatedAt","relearnedAt","systemLearned",
                "actualDefectQty","actualPerProducedQty","actualDefectRate"))
            assertTrue(edgeKeys.contains(key),()->key+" missing in "+edgeKeys);
        assertFalse(edgeKeys.contains("usage"));
        assertTrue(json.has("canRelearn"));
        assertEquals(0,new BigDecimal("100").compareTo(json.get("profile").get("totalDefectQty").decimalValue()));
    }

    private GoodsBomLearningQueryService service() {
        EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->jdbcQuery(call.getArgument(0)));
        MasterObjectAccess access=mock(MasterObjectAccess.class);
        when(access.visibleGoodsOwner()).thenReturn(owner->true);
        return new GoodsBomLearningQueryService(em,mock(MasterReferenceValidationPort.class),access,
                mock(TxSessionVars.class),mock(SecurityContextCurrentUser.class),
                mock(GoodsBomMaterialEvidenceQuery.class));
    }

    /** 服务的原生 SQL 原样执行：命名参数按出现顺序换成 JDBC 占位符(:: 类型转换不动)。 */
    private Query jdbcQuery(String sql) {
        Map<String,Object> params=new HashMap<>();
        Query query=mock(Query.class);
        when(query.setParameter(anyString(),any())).thenAnswer(call->{params.put(call.getArgument(0),call.getArgument(1));return query;});
        when(query.getResultList()).thenAnswer(call->{
            Matcher named=Pattern.compile("(?<!:):([A-Za-z]\\w*)").matcher(sql);
            StringBuilder jdbc=new StringBuilder();List<Object> args=new ArrayList<>();
            while(named.find()){args.add(params.get(named.group(1)));named.appendReplacement(jdbc,"?");}
            named.appendTail(jdbc);
            try(var statement=db.prepareStatement(jdbc.toString())) {
                for(int i=0;i<args.size();i++)statement.setObject(i+1,args.get(i));
                try(var rows=statement.executeQuery()) {
                    List<Object[]> result=new ArrayList<>();int width=rows.getMetaData().getColumnCount();
                    while(rows.next()){Object[] row=new Object[width];for(int i=0;i<width;i++)row[i]=rows.getObject(i+1);result.add(row);}
                    return result;
                }
            } catch(SQLException e) {throw new IllegalStateException(e);}
        });
        return query;
    }

    private UUID unit(String name)throws Exception {UUID id=UUID.randomUUID();sql("INSERT INTO units(id,name) VALUES(?,?)",id,name);return id;}
    private UUID goods(String code)throws Exception {
        UUID id=UUID.randomUUID();
        sql("INSERT INTO goods(id,code,name,unit_id,is_deleted,auto_created) VALUES(?,?,?,?,false,false)",id,code,"名称"+code,unit);
        return id;
    }
    /** 一条学习累计(良品暴露产量与不良数)；relearned=true 表示全部累计已记为基线(重新学习后还没有新数据)。 */
    private void usage(UUID parent,UUID component,UUID outputUnit,String net,String exposure,String defect,long samples,
                       boolean relearned)throws Exception {
        BigDecimal netQty=new BigDecimal(net),exposureQty=new BigDecimal(exposure),defectQty=new BigDecimal(defect);
        sql("INSERT INTO goods_bom_actual_usages(goods_id,component_goods_id,unit_id,output_unit_id,net_qty,exposure_output_qty,"
                        +"exposure_defect_qty,sample_count,baseline_net_qty,baseline_exposure_output_qty,baseline_exposure_defect_qty,"
                        +"baseline_sample_count,relearned_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                parent,component,unit,outputUnit,netQty,exposureQty,defectQty,samples,relearned?netQty:BigDecimal.ZERO,
                relearned?exposureQty:BigDecimal.ZERO,relearned?defectQty:BigDecimal.ZERO,relearned?samples:0L,
                relearned?java.sql.Timestamp.from(java.time.Instant.now()):null);
    }
    private static Set<String> keys(JsonNode node){Set<String> keys=new TreeSet<>();node.fieldNames().forEachRemaining(keys::add);return keys;}
    private static Connection connection()throws SQLException{return DriverManager.getConnection(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword());}
    private void sql(String sql,Object...args)throws SQLException {
        try(var statement=db.prepareStatement(sql)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);statement.execute();}
    }
    private static void amount(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),actual::toPlainString);}
}
