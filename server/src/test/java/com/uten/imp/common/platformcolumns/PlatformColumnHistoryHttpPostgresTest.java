package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import org.junit.jupiter.api.Test;
import org.flywaydb.core.Flyway;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Native sales owner scope, immutable original-parent lookup, and price masking through real HTTP/PG. */
class PlatformColumnHistoryHttpPostgresTest extends AiPlatformPostgresTestSupport {
    private static final AtomicInteger NUMBER=new AtomicInteger(870000);
    private static final UUID LEGACY_ORDER=UUID.randomUUID(),LEGACY_ITEM=UUID.randomUUID();

    @DynamicPropertySource
    static void genuinePreRetentionRow(DynamicPropertyRegistry unused) {
        POSTGRES.start();
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword()).target("774").load().migrate();
        var sql=new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword()));
        UUID employee=UUID.randomUUID(),actor=UUID.randomUUID(),client=UUID.randomUUID(),unit=UUID.randomUUID(),goods=UUID.randomUUID();
        sql.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'旧字段测试归属','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_HR'",employee,"EMP-LEGACY-"+employee);
        sql.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",actor,employee,"legacy-field-"+actor);
        sql.update("INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id) VALUES(?,'C-LEGACY-FH','旧字段客户','使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients),?)",client,employee);
        sql.update("INSERT INTO units(id,code,name,status) VALUES(?,'U-LEGACY-FH','旧字段单位','使用')",unit);
        sql.update("INSERT INTO goods(id,code,name,model,source_type,status,unit_id,price,code_sequence) VALUES(?,'G-LEGACY-FH','旧字段货品','LEGACY-FH','自制','使用',?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",goods,unit);
        insertShipment(sql,LEGACY_ORDER,LEGACY_ITEM,client,employee,goods,unit,"G-LEGACY-FH",879999);
        // Spring then applies the immutable V775..V779 forward chain. No trigger is disabled.
    }

    @Test void existingUnregisteredAndRetiredItemsRemainReadableAfterParentLogicalDeletion() throws Exception {
        Fixture f=fixture(true);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_record_identities WHERE source_table='sales_shipment_items' AND source_id=?",Integer.class,f.item().toString())).isZero();
        assertPublicOriginal(history(f));
        // A current shipment keeps an active replacement line. Retiring the old line is a legal soft transition.
        var tx=new org.springframework.transaction.support.TransactionTemplate(new org.springframework.jdbc.datasource.DataSourceTransactionManager(jdbc.getDataSource()));
        tx.executeWithoutResult(ignored->{
            jdbc.update("INSERT INTO sales_shipment_items(id,shipment_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source) SELECT ?,shipment_id,bill_no,bill_date,line_no+1,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source FROM sales_shipment_items WHERE id=?",UUID.randomUUID(),f.item());
            jdbc.update("UPDATE sales_shipment_items SET is_deleted=true,deleted_at=now() WHERE id=?",f.item());
        });
        assertThat(jdbc.queryForObject("SELECT parent_id FROM business_record_identities WHERE source_table='sales_shipment_items' AND source_id=?",String.class,f.item().toString())).isEqualTo(f.order().toString());
        assertPublicOriginal(history(f));
        tx.executeWithoutResult(ignored->{
            jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,f.seller().userId());
            jdbc.update("UPDATE sales_shipments SET is_deleted=true,deleted_at=now() WHERE id=?",f.order());
        });
        assertThat(jdbc.queryForObject("SELECT actor_id FROM business_record_history WHERE source_table='sales_shipments' AND source_id=? AND operation='SOFT_DELETE' ORDER BY id DESC LIMIT 1",UUID.class,f.order().toString())).isEqualTo(UUID.fromString(f.seller().userId()));
        var active=mvc.perform(get("/api/sales/shipments/"+f.order()).header("Authorization","Bearer "+f.seller().token())).andReturn();
        assertThat(active.getResponse().getStatus()).isEqualTo(404);
        assertPublicOriginal(history(f));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='view_platform_field_history_detail' AND target_id=? AND actor_id=?",Integer.class,f.item().toString(),UUID.fromString(f.seller().userId())))
            .as("Same actor/session/object refreshes retain the existing 30-minute first-view audit contract")
            .isEqualTo(1);
    }

    @Test void nativePriceMaskHidesRetainedValuesWithoutChangingOriginalContents() throws Exception {
        Fixture f=fixture();
        var nativeDetail=getJson("/api/sales/shipments/"+f.order()+"/history",f.seller().token());
        assertThat(nativeDetail.path("priceMasked").asBoolean()).isTrue();
        var cells=history(f).get(0).path("row").path("cells");
        var sensitive=cell(cells,f.secret());
        assertThat(sensitive.path("masked").asBoolean()).isTrue();
        assertThat(sensitive.path("value").isNull()).isTrue();
        assertThat(sensitive.path("definition").path("formula").isNull()).isTrue();
        assertThat(jdbc.queryForObject("SELECT cells::text FROM platform_record_field_versions WHERE record_id=?",String.class,f.item())).contains("120.30","old-original-value");
        assertPublicOriginal(history(f));
    }

    @Test void withdrawingCurrentParentScopeRefusesOldValuesAndDoesNotWriteSuccessfulView() throws Exception {
        Fixture f=fixture();assertPublicOriginal(history(f));
        UUID anotherOwner=jdbc.queryForObject("SELECT employee_id FROM users WHERE login_account=?",UUID.class,ADMIN_LOGIN);
        jdbc.update("UPDATE sales_shipments SET owner_employee_id=? WHERE id=?",anotherOwner,f.order());
        var denied=mvc.perform(get(path(f)).header("Authorization","Bearer "+f.seller().token())).andReturn();
        assertThat(denied.getResponse().getStatus()).isEqualTo(404);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='view_platform_field_history_detail' AND target_id=? AND actor_id=?",Integer.class,f.item().toString(),UUID.fromString(f.seller().userId()))).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT cells::text FROM platform_record_field_versions WHERE record_id=?",String.class,f.item())).contains("120.30","old-original-value");
    }

    private Fixture fixture() throws Exception {return fixture(false);}
    private Fixture fixture(boolean legacy) throws Exception {
        jdbc.update("""
            INSERT INTO department_permissions(department_id,permission_id)
            SELECT d.id,p.id FROM departments d,permissions p WHERE d.code='DEPT_HR' AND p.code IN('sales_shipment:view','sales_other_shipment:view')
            ON CONFLICT DO NOTHING
            """);
        Staff seller=newEmployee(adminToken(),"DEPT_HR");
        UUID employee=UUID.fromString(seller.employeeId()),actor=UUID.fromString(seller.userId());
        UUID client=UUID.randomUUID(),goods=UUID.randomUUID(),unit=UUID.randomUUID(),order=UUID.randomUUID(),item=UUID.randomUUID();
        String tag=UUID.randomUUID().toString().substring(0,8);
        if(legacy){order=LEGACY_ORDER;item=LEGACY_ITEM;jdbc.update("UPDATE sales_shipments SET owner_employee_id=? WHERE id=?",employee,order);}
        else {
            jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id) VALUES(?,?,?,'使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients),?)",client,"C-FH-"+tag,"历史字段客户",employee);
            jdbc.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')",unit,"U-FH-"+tag,"历史字段单位"+tag);
            jdbc.update("INSERT INTO goods(id,code,name,model,source_type,status,unit_id,price,code_sequence) VALUES(?,?,'历史字段货品',?,'自制','使用',?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",goods,"G-FH-"+tag,tag,unit);
            insertShipment(jdbc,order,item,client,employee,goods,unit,"G-FH-"+tag,NUMBER.incrementAndGet());
        }
        UUID note=UUID.randomUUID(),secret=UUID.randomUUID();
        definition(note,"保留原备注","TEXT",false,actor);definition(secret,"保留原金额","NUMBER",true,actor);
        String cells="[{\"columnId\":\""+note+"\",\"value\":\"old-original-value\"},{\"columnId\":\""+secret+"\",\"value\":\"120.30\"}]";
        jdbc.update("INSERT INTO platform_record_fields(scope,record_id,version,cells,created_by,updated_by) VALUES('sales_shipment_item',?,1,CAST(? AS jsonb),?,?)",item,cells,actor,actor);
        return new Fixture(seller,order,item,note,secret);
    }
    private static void insertShipment(JdbcTemplate db,UUID shipment,UUID item,UUID client,UUID employee,UUID goods,UUID unit,String goodsCode,int number){
        var tx=new org.springframework.transaction.support.TransactionTemplate(new org.springframework.jdbc.datasource.DataSourceTransactionManager(db.getDataSource()));
        tx.executeWithoutResult(ignored->{
            db.update("INSERT INTO sales_shipments(id,bill_no,bill_date,status,client_id,owner_employee_id,maker_id,shipment_kind,billing_mode,direct_purpose,warehouse_work_status,warehouse_chosen_at_pick,finance_gate_version,finance_audit,total_original,total_local) VALUES(?,'XC'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||?,CURRENT_DATE,0,?,?,?,'DIRECT_CUSTOMER','CHARGED','SAMPLE','PENDING_PICK',true,2,0,20,20)",shipment,Integer.toString(number),client,employee,employee);
            db.update("INSERT INTO sales_shipment_items(id,shipment_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source) SELECT ?,h.id,h.bill_no,h.bill_date,1,?,?,1,2,10,20,20,?,'历史字段货品','MASTER_AT_SAVE' FROM sales_shipments h WHERE h.id=?",item,goods,unit,goodsCode,shipment);
        });
    }
    private void definition(UUID id,String name,String type,boolean price,UUID actor){
        jdbc.update("INSERT INTO platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,definition_fingerprint,created_by) VALUES(?,'sales_shipment_item',?,?,?,?,?,?)",id,name,name,type,price,id.toString().replace("-","")+"a".repeat(32),actor);
    }
    private JsonNode history(Fixture f) throws Exception{return getJson(path(f),f.seller().token());}
    private String path(Fixture f){return "/api/platform-columns/sales_shipment_item/values/"+f.item()+"/history";}
    private void assertPublicOriginal(JsonNode rows){
        assertThat(rows.isArray()).isTrue();assertThat(rows.size()).isEqualTo(1);
        assertThat(rows.get(0).path("historyReadOnly").asBoolean()).isTrue();
        assertThat(rows.get(0).path("row").path("canWrite").asBoolean()).isFalse();
        assertThat(rows.get(0).path("row").path("cells").get(0).path("value").asText()).isEqualTo("old-original-value");
    }
    private JsonNode cell(JsonNode cells,UUID id){for(var cell:cells)if(cell.path("columnId").asText().equals(id.toString()))return cell;throw new AssertionError("Missing retained field");}
    private record Fixture(Staff seller,UUID order,UUID item,UUID note,UUID secret){}
}
