package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.*;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.goods.GoodsCostMasker;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.time.OffsetDateTime;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual current SQL/JSON shapes and customer ACL predicates, without writing any business database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsCostVersionsPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withCreateContainerCmdModifier(command->command.getHostConfig().withMemory(768L*1024*1024).withNanoCPUs(1_000_000_000L));
    private static DriverManagerDataSource source;
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private final UUID actor=UUID.randomUUID(),goods=UUID.randomUUID(),client=UUID.randomUUID(),hiddenClient=UUID.randomUUID(),
            unit=UUID.randomUUID(),currency=UUID.randomUUID(),euro=UUID.randomUUID(),privateMaterial=UUID.randomUUID();
    private final GoodsCostJson json=new GoodsCostJson(new ObjectMapper().findAndRegisterModules());
    private MasterReferenceValidationPort references;
    private SecurityContextCurrentUser current;
    private OwnerVisibility owners;
    private GoodsCostSheetService service;
    private TransactionTemplate transactions;
    @BeforeAll static void start(){
        PG.start();source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"goods","clients","client_co_owners","client_visibility_grants",
                "units","currencies","goods_cost_sheets");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void setup(){
        db.update("INSERT INTO goods(id,code,name,unit_id,source_type) VALUES(?,?,?,?,'自制')",goods,"COST-V-"+goods,"版本货品",unit);
        db.update("INSERT INTO clients(id,code,name,owner_employee_id) VALUES(?,?,?,?),(?,?,?,?)",
                client,"COST-C-"+client,"可见客户",actor,hiddenClient,"COST-C-"+hiddenClient,"不可见客户",UUID.randomUUID());
        references=mock(MasterReferenceValidationPort.class);doCallRealMethod().when(references).requireVisibleGoodsBatch(anyCollection());
        current=mock(SecurityContextCurrentUser.class);permissions(Set.of("goods:view","goods:cost:view"));
        owners=mock(OwnerVisibility.class);when(owners.evaluate("client","client:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(actor)));
        EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0);Query query=mock(Query.class);Map<String,Object> parameters=new LinkedHashMap<>();
            when(query.setParameter(anyString(),any())).thenAnswer(call->{parameters.put(call.getArgument(0),call.getArgument(1));return query;});
            when(query.getResultList()).thenAnswer(call->named.query(sql,parameters,(rs,index)->new Object[]{rs.getObject(1)}));
            return query;
        });
        var clients=new ClientAccessPolicy(owners,current,em);
        var mask=mock(GoodsCostMasker.class);when(mask.canView()).thenReturn(true);
        service=new GoodsCostSheetService(named,mock(GoodsCostCalculator.class),json,mask,references,clients,current,
                mock(TxSessionVars.class),mock(CostImportEvidenceGuard.class));
        transactions=new TransactionTemplate(new DataSourceTransactionManager(source));
        transactions.setIsolationLevel(org.springframework.transaction.TransactionDefinition.ISOLATION_REPEATABLE_READ);
    }
    private void permissions(Set<String> permissions){when(current.get()).thenReturn(Optional.of(new AuthUser(actor,actor,"cost-version-reader",permissions,false,true,false)));}
    private UUID seed(String name,UUID owner,UUID denomination,String amount,long version,String batch,OffsetDateTime at,boolean privateLine){
        UUID id=UUID.randomUUID();Map<String,Object> input=new LinkedHashMap<>();
        input.put("goodsId",goods);input.put("clientId",owner);input.put("name",name);input.put("batchQty",batch);
        input.put("currencyId",denomination);input.put("exchangeRateToLocal","1");input.put("effectiveDate","2026-10-01");
        input.put("lineOverrides",List.of());input.put("fees",List.of());input.put("priceColumns",List.of());input.put("priceCells",List.of());input.put("extraFields",Map.of());
        Map<String,Object> total=new LinkedHashMap<>();total.put("knownTotal",amount);total.put("unitCost",amount);
        total.put("valueState",amount==null?"PARTIAL":"COMPLETE");total.put("byCategory",Map.of());
        Map<String,Object> calculation=new LinkedHashMap<>();calculation.put("algorithmVersion","stored-fixture");calculation.put("calculatedAt",at);
        calculation.put("goodsId",goods);calculation.put("unitId",unit);calculation.put("unitName","历史件");calculation.put("currencyId",denomination);
        calculation.put("currencyName",denomination==null?null:denomination.equals(currency)?"历史美金":"历史欧元");
        calculation.put("batchQty",batch);calculation.put("lines",privateLine?List.of(Map.of("goodsId",privateMaterial)):List.of());
        calculation.put("fees",List.of());calculation.put("totals",total);calculation.put("issues",List.of());calculation.put("sourceRevisions",Map.of());
        db.update("INSERT INTO goods_cost_sheets(id,sheet_no,goods_id,client_id,name,status,row_version,input,calculation,created_by,updated_by,updated_at)"
                +" VALUES(?,?,?,?,?,'DRAFT',?,CAST(? AS jsonb),CAST(? AS jsonb),?,?,?)",
                id,"CB-"+id,goods,owner,name,version,json.write(input),json.write(calculation),actor,actor,at);
        return id;
    }
    private GoodsCostContracts.VersionPage page(int page,int size,String denomination,Map<String,String> searches,String sort,String order){
        return transactions.execute(status->service.versions(goods,page,size,null,denomination,searches,sort,order));
    }
    @Test void completeScopeFindsAnOlderAuthorizedVersionBeyondTheFormer250AndKeepsExactTypedFacts(){
        OffsetDateTime newer=OffsetDateTime.parse("2026-11-01T00:00:00Z");
        for(int i=0;i<251;i++) {
            UUID hidden=seed("不可见"+i,hiddenClient,currency,"999",1,"1",newer.plusDays(1).plusSeconds(i),false);
            // These bodies must never be parsed by an unauthorized customer read.
            db.update("UPDATE goods_cost_sheets SET calculation='{}'::jsonb WHERE id=?",hidden);
        }
        for(int i=0;i<300;i++)seed("近期方案"+i,client,currency,"1",1,"1",newer.plusSeconds(i),false);
        UUID target=seed("唯一 旧版_%",client,currency,"0.1234567890123456789",9007199254740993L,
                "9007199254740993.0001",OffsetDateTime.parse("2026-10-27T16:15:00Z"),false);
        var first=page(1,50,null,Map.of(),null,null);assertThat(first.total()).isEqualTo(301);assertThat(first.items()).hasSize(50);
        var last=page(7,50,null,Map.of(),null,null);assertThat(last.total()).isEqualTo(301);assertThat(last.items()).singleElement().satisfies(row->assertThat(row.id()).isEqualTo(target));
        var recent=transactions.execute(status->service.list(goods));assertThat(recent).hasSize(250).noneMatch(row->row.clientId().equals(hiddenClient)||row.id().equals(target));
        var searches=Map.of("name","唯一 旧版_%","version",">9007199254740992","batchQty","9007199254740993.0001",
                "knownTotal",">=0.1234567890123456789","updatedAt","2026-10-28","unitName","历史 件","currencyName","历史 美金");
        var filtered=page(1,1,currency.toString(),searches,"knownTotal","desc");
        assertThat(filtered.total()).isEqualTo(1);assertThat(filtered.items()).singleElement().satisfies(row->{
            assertThat(row.id()).isEqualTo(target);assertThat(row.knownTotal()).isEqualTo("0.1234567890123456789");
            assertThat(row.versionExact()).isEqualTo("9007199254740993");assertThat(row.unitName()).isEqualTo("历史件");
        });
        assertThat(page(2,1,currency.toString(),searches,"knownTotal","desc").items()).isEmpty();
    }
    @Test void currencyCandidatesUseTheCompleteAuthorizedIntersectionAndPrivateMaterialsNeverBecomeAPriceOracle(){
        OffsetDateTime at=OffsetDateTime.parse("2026-10-28T00:00:00Z");
        seed("可比较美元",client,currency,"12",1,"1",at,false);seed("可比较欧元",client,euro,"0.01",1,"1",at,false);
        UUID unknown=seed("可比较未知币",client,null,null,1,"1",at,false);
        seed("可比较隐藏材料",client,currency,"99",1,"1",at,true);
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(references).requireVisibleGoods(privateMaterial);
        var result=page(1,50,currency.toString(),Map.of("name","可比较","knownTotal",">=10"),null,null);
        assertThat(result.total()).isEqualTo(1);
        assertThat(result.facets().get("currencyName")).extracting(FacetBucket::value)
                .containsExactlyInAnyOrder(currency.toString(),euro.toString(),"__null__");
        assertThat(result.facets().get("currencyName")).allSatisfy(bucket->assertThat(bucket.count()).isEqualTo(1));
        assertThat(page(1,50,currency.toString(),Map.of("name","可比较","knownTotal","99"),null,null).total()).isZero();
        var missing=page(1,50,"__null__",Map.of(),null,null);
        assertThat(missing.items()).singleElement().satisfies(row->{assertThat(row.id()).isEqualTo(unknown);assertThat(row.knownTotal()).isNull();});
        doThrow(new ApiException(ErrorCode.PRIMARY_UNAVAILABLE)).when(references).requireVisibleGoods(privateMaterial);
        assertThatThrownBy(()->page(1,50,null,Map.of(),null,null)).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.PRIMARY_UNAVAILABLE));
    }
    @Test void costAuthorityPrecedesHeaderParsingAndAnyVersionProbe(){
        permissions(Set.of("goods:view"));
        assertThatThrownBy(()->page(1,50,null,Map.of("knownTotal","not a number"),"knownTotal","desc"))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        verifyNoInteractions(references,owners);
    }
}
