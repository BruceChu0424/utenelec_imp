package com.uten.imp.features.master;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.DepartmentNameResolver;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.client.Client;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.goods.*;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.*;
import com.uten.imp.features.master.mould.dto.MouldQueryFilter;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.mouldcategory.MouldCategoryRepository;
import com.uten.imp.features.master.search.MasterColumnSearch;
import com.uten.imp.features.master.supplier.*;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/** Real Hibernate numeric predicates and derived projections over current catalog shapes and original loss views. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MasterNumericHeadersPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static jakarta.persistence.EntityManagerFactory emf;
    private static JdbcTemplate db;
    private EntityManager em;
    private JpaRepositoryFactory repositories;
    @BeforeAll static void baseline() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("master_numeric_headers");
        try(var connection=database.openConnection();var statement=connection.createStatement()) {
            statement.execute("CREATE SCHEMA master_header_oracle");
            statement.execute("SET search_path=master_header_oracle,public");
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"goods","goods_bom_items","colors","units",
                    "material_categories","moulds","mould_categories","clients","client_categories","suppliers","supplier_categories",
                    "stock_balances","warehouses","employees","departments","positions","subcontract_orders","subcontract_order_items","subcontract_short_delivery_cases","procurement_order_qty_change_logs");
        }
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        var properties=new java.util.Properties();properties.setProperty("currentSchema","master_header_oracle,public");
        source.setConnectionProperties(properties);db=new JdbcTemplate(source);
        for(String view:java.util.List.of("v_subcontract_supplier_goods_loss_summary","v_subcontract_supplier_loss_summary")) {
            String definition=db.queryForObject("SELECT pg_get_viewdef(CAST(? AS regclass),true)",String.class,"public."+view);
            db.execute("CREATE VIEW "+view+" AS "+definition.replace("public.","master_header_oracle."));
        }
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(Goods.class.getName(),GoodsBomItem.class.getName(),Color.class.getName(),Unit.class.getName(),
                MaterialCategory.class.getName(),Mould.class.getName(),MouldCategory.class.getName(),Client.class.getName(),ClientCategory.class.getName(),
                Supplier.class.getName(),SupplierCategory.class.getName(),com.uten.imp.features.master.warehouse.Warehouse.class.getName(),
                com.uten.imp.features.org.employee.Employee.class.getName(),com.uten.imp.features.org.department.Department.class.getName(),
                com.uten.imp.features.org.position.Position.class.getName()));
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none","hibernate.jdbc.time_zone","UTC"));factory.afterPropertiesSet();emf=factory.getObject();
    }
    @AfterAll static void close() throws Exception { if(emf!=null)emf.close();if(database!=null)database.close(); }
    @BeforeEach void clean() {
        db.execute("TRUNCATE goods,goods_bom_items,moulds,clients,suppliers,stock_balances,warehouses,subcontract_orders,subcontract_order_items,subcontract_short_delivery_cases,procurement_order_qty_change_logs");
        em=emf.createEntityManager();repositories=new JpaRepositoryFactory(em);
    }
    @AfterEach void closeEntityManager() { if(em!=null)em.close(); }

    @Test void goodsHeadersUseDisplayedNumbersAuthorisedRowsAndTheSameGoodStockBoundaryBeforePagingAndLocation() {
        UUID owner=UUID.randomUUID(),hidden=UUID.randomUUID();
        UUID first=goods("H-01",owner),second=goods("H-02",owner),privateGoods=goods("H-03",hidden);
        UUID good=warehouse(false,false),defective=warehouse(true,false),lineSide=warehouse(false,true);
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES(?,?,12),(?,?,24),(?,?,99),(?,?,777),(?,?,888)",
                good,first,good,second,good,privateGoods,defective,first,lineSide,first);
        var scope=mock(GoodsReadScopePolicy.class);when(scope.evaluate()).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(owner)));
        var actor=mock(SecurityContextCurrentUser.class);
        when(actor.get()).thenReturn(java.util.Optional.of(new AuthUser(UUID.randomUUID(),owner,"reader",Set.of("goods:price:view","goods:discount:view"),false,true,false)));
        var service=new GoodsService(repositories.getRepository(GoodsRepository.class),mock(MaterialCategoryRepository.class),
                mock(com.uten.imp.features.master.color.ColorRepository.class),mock(com.uten.imp.features.master.unit.UnitRepository.class),
                mock(MouldRepository.class),mock(TxSessionVars.class),em,mock(CategoryDrivenCodeService.class),mock(OwnerVisibility.class),
                actor,mock(GoodsCostMasker.class),mock(GoodsMasterRelationshipResolver.class),scope);
        var filter=new GoodsQueryFilter(null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,
                false,false,false,false,null,null,false).withColumnSearch(Map.of("clientGoodsName","客户%_货名","price","12.35",
                        "discount","0.9","stockQty",">=10","minOrderQty","10..10","orderMultipleQty","2"));
        var page1=service.list(filter,1,1,"stockQty","desc");
        var page2=service.list(filter,2,1,"stockQty","desc");
        assertThat(page1.getTotal()).isEqualTo(2);
        assertThat(page1.getItems().getFirst().getId()).isEqualTo(second);
        assertThat(page2.getItems().getFirst().getId()).isEqualTo(first);
        assertThat(page2.getItems().getFirst().getStockQty()).isEqualByComparingTo("12");
        assertThat(page2.getItems().getFirst().getPriceDisplayText()).isEqualTo("12.35");
        assertThat(page2.getItems().getFirst().getStockQtyDisplayText()).isEqualTo("12.00");
        assertThat(service.locate(filter,first,1,"stockQty","desc").page()).isEqualTo(2);
        assertThat(service.locate(filter,second,1,"stockQty","desc").page()).isEqualTo(1);
        assertThat(service.locate(filter,privateGoods,1,"stockQty","desc").found()).isFalse();
        UUID half=goods("H-HALF",owner);
        db.update("UPDATE goods SET price=1.005 WHERE id=?",half);
        var halfPage=service.list(filter.withColumnSearch(Map.of("price","1.01")),1,20,null,null);
        assertThat(halfPage.getItems().getFirst().getId()).isEqualTo(half);
        assertThat(halfPage.getItems().getFirst().getPriceDisplayText()).isEqualTo("1.01");
        when(actor.get()).thenReturn(java.util.Optional.of(new AuthUser(UUID.randomUUID(),owner,"reader",Set.of(),false,true,false)));
        org.assertj.core.api.Assertions.assertThatThrownBy(()->service.list(filter,1,20,null,null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("价格查看权限");
        org.assertj.core.api.Assertions.assertThatThrownBy(()->service.list(filter.withColumnSearch(Map.of()),1,20,"discount","asc"))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("折扣查看权限");
    }

    @Test void supplierLossHeadersUseTheOriginalWeightedViewAndKeepUnknownHistoryDistinctFromZero() {
        UUID first=supplier("S-01"),second=supplier("S-02"),zero=supplier("S-03"),unknown=supplier("S-04"),deleted=supplier("S-05");
        loss(first,"100","10");loss(second,"100","20");loss(zero,"100","0");loss(deleted,"100","90");
        db.update("UPDATE suppliers SET is_deleted=true WHERE id=?",deleted);
        assertThat(db.queryForObject("SELECT loss_pct FROM v_subcontract_supplier_loss_summary WHERE supplier_id=?",java.math.BigDecimal.class,first))
                .as("original weighted view over migrated projection tables").isEqualByComparingTo("10");
        var service=new SupplierService(repositories.getRepository(SupplierRepository.class),mock(SupplierCategoryRepository.class),
                mock(TxSessionVars.class),em,mock(CategoryDrivenCodeService.class),mock(EmployeeRepository.class),mock(EmployeeNameResolver.class));
        var filter=new SupplierQueryFilter(null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,false)
                .withColumnSearch(Map.of("lossRate","10..20","name","供应%_商"));
        assertThat(service.list(filter.withColumnSearch(Map.of("name","供应%_商")),1,20,null,null).getTotal())
                .as("literal header text remains independent of the numeric read model").isEqualTo(4);
        assertThat(service.list(filter.withColumnSearch(Map.of("lossRate","10..20")),1,20,null,null).getTotal())
                .as("weighted numeric read model before pagination").isEqualTo(2);
        var page1=service.list(filter,1,1,"lossRate","desc");
        var page2=service.list(filter,2,1,"lossRate","desc");
        assertThat(page1.getTotal()).isEqualTo(2);
        assertThat(page1.getItems().getFirst().getId()).isEqualTo(second);
        assertThat(page2.getItems().getFirst().getId()).isEqualTo(first);
        assertThat(page1.getItems().getFirst().getLossRate()).isEqualByComparingTo("20");
        var zeroOnly=service.list(filter.withColumnSearch(Map.of("lossRate","0")),1,20,null,null);
        assertThat(zeroOnly.getItems()).extracting(com.uten.imp.features.master.supplier.dto.SupplierListItem::getId).containsExactly(zero);
        assertThat(service.list(filter.withColumnSearch(Map.of()),1,20,"lossRate","asc").getItems().getLast().getId()).isEqualTo(unknown);
        assertThat(service.export(filter,"lossRate","desc",50).rows()).hasSize(2);
    }

    @Test void mouldAndClientNumericHeadersUseTheirOwnColumnsAndDoNotTreatTheMouldCavityFormulaAsANumber() {
        UUID small=UUID.randomUUID(),large=UUID.randomUUID();
        db.update("INSERT INTO moulds(id,code,name,qty,tqty,is_deleted,code_managed) VALUES(?,'M1','模具','1+1',2,false,false),(?,'M2','模具','1+1',12,false,false)",small,large);
        var service=new MouldService(repositories.getRepository(MouldRepository.class),mock(MouldCategoryRepository.class),mock(TxSessionVars.class),
                em,mock(CategoryDrivenCodeService.class),mock(DepartmentNameResolver.class),mock(EmployeeNameResolver.class));
        var filter=new MouldQueryFilter(null,null,null,null,null,null,null,null,null,null,null).withColumnSearch(Map.of("tqty",">=2","qty","1+1"));
        assertThat(service.list(filter,1,1,"tqty","desc").getItems().getFirst().getId()).isEqualTo(large);
        assertThat(service.list(filter,2,1,"tqty","desc").getItems().getFirst().getId()).isEqualTo(small);
        UUID customer=UUID.randomUUID();
        db.update("INSERT INTO clients(id,code,name,tday,credit,credit_floor,is_deleted,version,code_managed) VALUES(?,'C1','客户',30,12.3456,10.1234,false,0,false)",customer);
        var cb=em.getCriteriaBuilder();var query=cb.createQuery(UUID.class);var root=query.from(Client.class);
        query.select(root.get("id")).where(MasterColumnSearch.predicate(cb,root.get("id"),MasterColumnSearch.Domain.CLIENT,
                Map.of("tday",">=30","credit","12.35","creditFloor","10.12")));
        assertThat(em.createQuery(query).getResultList()).containsExactly(customer);
    }
    private UUID goods(String code,UUID owner) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO goods(id,code,name,client_goods_name,price,zk,min_order_qty,order_multiple_qty,owner_employee_id,is_deleted,auto_created,code_managed,is_recycled_material,version) VALUES(?,?,'货品','客户%_货名',12.3456,0.9,10,2,?,false,false,false,false,0)",id,code,owner);return id;
    }
    private UUID warehouse(boolean defective,boolean lineSide) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,is_accountable,is_defective,is_line_side) VALUES(?,true,?,?)",id,defective,lineSide);return id;
    }
    private UUID supplier(String code) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO suppliers(id,code,name,is_deleted,is_internal_workshop,code_managed,version) VALUES(?,?,'供应%_商',false,false,false,0)",id,code);return id;
    }
    private void loss(UUID supplier,String ordered,String loss) {
        UUID order=UUID.randomUUID(),line=UUID.randomUUID();
        db.update("INSERT INTO subcontract_orders(id,supplier_id,status,is_deleted) VALUES(?,?,1,false)",order,supplier);
        var contract=new java.math.BigDecimal(ordered);var shortage=new java.math.BigDecimal(loss);
        boolean natural=shortage.signum()==0;
        db.update("INSERT INTO subcontract_order_items(id,order_id,goods_id,qty,received_qty,returned_qty,is_deleted) VALUES(?,?,?,?,?,0,false)",
                line,order,UUID.randomUUID(),contract.subtract(shortage),natural?contract:java.math.BigDecimal.ZERO);
        if(natural)return;
        // V688 reports legacy quantity-revision loss exactly once. New independent
        // loss needs a valid waste/settlement lifecycle and is exercised by its owning command tests.
        UUID revision=UUID.randomUUID();
        db.update("INSERT INTO procurement_order_qty_change_logs(id,order_type,order_id,order_item_id,old_qty,new_qty,changed_at) VALUES(?,'SUBCONTRACT',?,?,?,?,now())",
                revision,order,line,contract,contract.subtract(shortage));
        db.update("INSERT INTO subcontract_short_delivery_cases(id,order_id,order_item_id,status,decision,ordered_qty,loss_qty,qty_change_log_id,closed_at) VALUES(?,?,?,'ACCEPTED_LOSS','ACCEPT_LOSS',?,?,?,now())",
                UUID.randomUUID(),order,line,contract,shortage,revision);
    }
}
