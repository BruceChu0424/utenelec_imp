package com.uten.imp.common.finance;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.math.BigDecimal;
import java.sql.*;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.mock;

/** Actual forward SQL and reviewed family projections. Replica mode isolates
 * unrelated posting fixtures while all quantity/lineage ALWAYS guards stay active.
 * Real authorized reversals and reposting are covered by the service E2E tests. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class UnapprovalFrozenAdoptionPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static final AtomicInteger NUMBERS=new AtomicInteger(970_000);
    private static final BigDecimal Q=new BigDecimal("1.000000000000000000000001");
    private static final BigDecimal BASE=new BigDecimal("1.000000000000000000000002");
    private static final String OLD_POLICY="{\"version\":1,\"choices\":{\"quantity.to-base\":{\"scale\":24,\"rounding\":\"DOWN\"},\"money.reference-unit-price\":{\"scale\":4,\"rounding\":\"DOWN\"}}}";
    private static final String OTHER_POLICY="{\"version\":1,\"choices\":{\"quantity.to-base\":{\"scale\":0,\"rounding\":\"DOWN\"},\"money.reference-unit-price\":{\"scale\":0,\"rounding\":\"DOWN\"}}}";
    private Connection db;
    private UUID actor,reviewer,unit,goods;
    private record Fixture(Owner owner,UUID original,UUID draft,UUID oldLine,UUID newLine,String draftNo) { }
    enum Owner {
        PURCHASE_ORDER("CD"),PURCHASE_RECEIPT("CJ"),PURCHASE_RETURN("CT"),
        SUBCONTRACT_ORDER("EO"),SUBCONTRACT_RECEIPT("EJ"),SUBCONTRACT_MATERIAL_RETURN("ER");
        final String prefix;
        Owner(String prefix){this.prefix=prefix;}
        DocumentUnapprovalPort adapter(){return switch(this){
            case PURCHASE_ORDER->new com.uten.imp.features.purchase.order.PurchaseOrderUnapprovalAdapter(mock(com.uten.imp.features.purchase.order.PurchaseOrderService.class));
            case PURCHASE_RECEIPT->new com.uten.imp.features.purchase.receipt.PurchaseReceiptUnapprovalAdapter(mock(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class));
            case PURCHASE_RETURN->new com.uten.imp.features.purchase.ret.PurchaseReturnUnapprovalAdapter(mock(com.uten.imp.features.purchase.ret.PurchaseReturnService.class));
            case SUBCONTRACT_ORDER->new com.uten.imp.features.subcontract.order.SubcontractOrderUnapprovalAdapter(mock(com.uten.imp.features.subcontract.order.SubcontractOrderService.class));
            case SUBCONTRACT_RECEIPT->new com.uten.imp.features.subcontract.receipt.SubcontractReceiptUnapprovalAdapter(mock(com.uten.imp.features.subcontract.receipt.SubcontractReceiptService.class));
            case SUBCONTRACT_MATERIAL_RETURN->new com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnUnapprovalAdapter(mock(com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService.class));
        };}
        boolean purchase(){return name().startsWith("PURCHASE");}
        boolean order(){return this==PURCHASE_ORDER||this==SUBCONTRACT_ORDER;}
    }

    @BeforeAll static void migrate() throws Exception {database=MigratedSchemaBaseline.openDatabase("unapproval_frozen");}
    @AfterAll static void closeDatabase() throws Exception {if(database!=null)database.close();}
    @BeforeEach void setup() throws Exception {
        db=database.openConnection();db.setAutoCommit(false);replica();
        actor=actor("source");reviewer=actor("reviewer");unit=UUID.randomUUID();goods=UUID.randomUUID();
        exec("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')",unit,"CLONE-U-"+unit,"个");
        exec("INSERT INTO goods(id,code,name,unit_id,code_sequence,code_managed) VALUES(?,?,?,?,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods),false)",goods,"CLONE-G-"+goods,"clone goods",unit);
        choose(OLD_POLICY,actor);
    }
    @AfterEach void rollback() throws Exception {if(db!=null){db.rollback();db.close();}}

    @ParameterizedTest @EnumSource(Owner.class)
    void inheritsTheOriginalFrozenFactsUnderAnotherActorsUnrelatedChoice(Owner owner) throws Exception {
        Fixture f=fixture(owner,false);String original=row(owner,f.oldLine());lineage(f,null);
        choose(OTHER_POLICY,reviewer);cloneLine(f,f.newLine(),f.oldLine(),f.draft());immediate();
        assertThat(row(owner,f.oldLine())).isEqualTo(original);
        if(owner!=Owner.SUBCONTRACT_ORDER){
            assertThat(decimal(owner,f.newLine(),owner.purchase()?"charged_base_qty":"adopted_base_qty")).isEqualByComparingTo(BASE);
            assertThat(text("SELECT quantity_precision_policy->'choices'->'quantity.to-base'->>'scale' FROM "+owner.adapter().lines().table()+" WHERE id=?",f.newLine())).isEqualTo("24");
            assertThat(text("SELECT quantity_adoption_version::text FROM "+owner.adapter().lines().table()+" WHERE id=?",f.newLine())).isEqualTo("2");
            if(owner.purchase())assertThat(decimal(owner,f.newLine(),"gift_base_qty")).isEqualByComparingTo(BASE);
        }
        assertThat(text("SELECT current_setting('app.business_precision_choices')::jsonb->'choices'->'quantity.to-base'->>'scale'")).isEqualTo("0");
        assertThat(uuid("SELECT unapproval_source_item_id FROM "+owner.adapter().lines().table()+" WHERE id=?",f.newLine())).isEqualTo(f.oldLine());
    }

    @ParameterizedTest @EnumSource(value=Owner.class,names={"PURCHASE_ORDER","SUBCONTRACT_ORDER"})
    void totalPriceReferenceProofIsInheritedWithoutRepricingTheAgreedTotal(Owner owner) throws Exception {
        Fixture f=fixture(owner,true);String original=row(owner,f.oldLine());lineage(f,null);
        choose(OTHER_POLICY,reviewer);cloneLine(f,f.newLine(),f.oldLine(),f.draft());immediate();
        assertThat(decimal(owner,f.newLine(),"total_amount_input")).isEqualByComparingTo("1");
        assertThat(decimal(owner,f.newLine(),"price")).isEqualByComparingTo("0.1666");
        assertThat(text("SELECT reference_price_precision_policy->'choices'->'money.reference-unit-price'->>'scale' FROM "+owner.adapter().lines().table()+" WHERE id=?",f.newLine())).isEqualTo("4");
        assertThat(row(owner,f.oldLine())).isEqualTo(original);
    }

    @ParameterizedTest @EnumSource(value=Owner.class,names={"PURCHASE_RECEIPT","SUBCONTRACT_RECEIPT","PURCHASE_RETURN","SUBCONTRACT_MATERIAL_RETURN"})
    void aLaterRealQuantityEditUsesItsNewExplicitAdoption(Owner owner) throws Exception {
        Fixture f=fixture(owner,false);lineage(f,null);choose(OTHER_POLICY,reviewer);cloneLine(f,f.newLine(),f.oldLine(),f.draft());
        db.commit();replica();choose("{\"version\":1,\"choices\":{\"quantity.to-base\":{\"scale\":12,\"rounding\":\"HALF_UP\"}}}",reviewer);
        String table=owner.adapter().lines().table();
        exec("UPDATE "+table+" SET qty=?"+(owner.purchase()?",charged_base_qty=2,gift_base_qty=1":",adopted_base_qty=2")+" WHERE id=?",Q.multiply(new BigDecimal("2")),f.newLine());
        assertThat(decimal(owner,f.newLine(),owner.purchase()?"charged_base_qty":"adopted_base_qty")).isEqualByComparingTo("2");
        assertThat(text("SELECT quantity_precision_policy->'choices'->'quantity.to-base'->>'scale' FROM "+table+" WHERE id=?",f.newLine())).isEqualTo("12");
        assertThat(decimal(owner,f.oldLine(),owner.purchase()?"charged_base_qty":"adopted_base_qty")).isEqualByComparingTo(BASE);
    }

    @Test void noLineageOrRolledBackLineageCannotAuthorizeAnOrigin() throws Exception {
        Fixture f=fixture(Owner.PURCHASE_RECEIPT,false);String before=row(f.owner(),f.oldLine());
        rejected("55000",()->cloneLine(f,f.newLine(),f.oldLine(),f.draft()));
        Savepoint prepared=db.setSavepoint();lineage(f,null);db.rollback(prepared);db.releaseSavepoint(prepared);
        rejected("55000",()->cloneLine(f,f.newLine(),f.oldLine(),f.draft()));
        assertThat(row(f.owner(),f.oldLine())).isEqualTo(before);
        assertThat(number("SELECT count(*) FROM document_unapprovals WHERE draft_id=?",f.draft())).isZero();
    }

    @Test void aCommittedLineageCannotBeReplayedForAnotherInsert() throws Exception {
        Fixture f=fixture(Owner.PURCHASE_RECEIPT,false);lineage(f,null);cloneLine(f,f.newLine(),f.oldLine(),f.draft());db.commit();
        replica();choose(OTHER_POLICY,reviewer);exec("DELETE FROM purchase_receipt_items WHERE id=?",f.newLine());
        rejected("55000",()->cloneLine(f,f.newLine(),f.oldLine(),f.draft()));
    }

    @Test void anotherFamilyHeaderOrSourceLineCannotBorrowTheProof() throws Exception {
        Fixture f=fixture(Owner.PURCHASE_RECEIPT,false);lineage(f,null);
        rejected("55000",()->cloneLine(f,UUID.randomUUID(),f.oldLine(),f.draft()));
        rejected("55000",()->cloneLine(f,f.newLine(),UUID.randomUUID(),f.draft()));
        rejected("55000",()->cloneLine(f,f.newLine(),f.oldLine(),UUID.randomUUID()));
        Fixture other=fixture(Owner.SUBCONTRACT_RECEIPT,false);
        lineage(other,null);
        rejected("55000",()->cloneLine(other,f.newLine(),f.oldLine(),other.draft()));
    }

    @Test void duplicateMappingsAndCallerWrittenTransactionProofAreRejected() throws Exception {
        Fixture f=fixture(Owner.PURCHASE_RECEIPT,false);
        String duplicate="{\""+f.oldLine()+"\":\""+f.newLine()+"\",\""+UUID.randomUUID()+"\":\""+f.newLine()+"\"}";
        rejected("23514",()->lineage(f,duplicate));
        rejected("55000",()->exec("INSERT INTO document_unapprovals(family,original_id,draft_id,draft_bill_no,request_key,reason,line_id_map,created_by,created_txid) VALUES(?,?,?,?,?,?,CAST(? AS jsonb),?,txid_current())",f.owner().adapter().family(),f.original(),f.draft(),f.draftNo(),"forged-source-tx-"+UUID.randomUUID(),"caller must not supply transaction proof",map(f),reviewer));
        lineage(f,null);
        rejected("23514",()->exec("UPDATE document_unapprovals SET created_txid=created_txid+1 WHERE draft_id=?",f.draft()));
    }

    @Test void incompleteLineageCannotCommitAndMetadataCannotBeRetagged() throws Exception {
        Fixture f=fixture(Owner.PURCHASE_RECEIPT,false);lineage(f,null);
        rejected("23514",this::immediate);
        choose(OTHER_POLICY,reviewer);cloneLine(f,f.newLine(),f.oldLine(),f.draft());immediate();
        String before=row(f.owner(),f.newLine());
        rejected("55000",()->exec("UPDATE purchase_receipt_items SET unapproval_source_item_id=NULL WHERE id=?",f.newLine()));
        rejected("23514","initial successor frozen facts cannot change in its assembly transaction",()->exec("UPDATE purchase_receipt_items SET charged_base_qty=1 WHERE id=?",f.newLine()));
        rejected("23514","initial successor frozen facts cannot change in its assembly transaction",()->exec("UPDATE purchase_receipt_items SET quantity_precision_policy=fn_business_precision_snapshot() WHERE id=?",f.newLine()));
        assertThat(row(f.owner(),f.newLine())).isEqualTo(before);
    }

    @Test void inheritedReceiptWeightKeepsTheOriginalRawEvidenceWithoutInventingAnotherInput() throws Exception {
        Fixture f=fixture(Owner.PURCHASE_RECEIPT,false);
        String originalPolicy="{\"version\":1,\"choices\":{\"weight.kg-field\":{\"scale\":24,\"rounding\":\"DOWN\"}}}";
        choose(originalPolicy,actor);
        BigDecimal raw=new BigDecimal("0.123456789012345678901234567890123456789012345678");
        BigDecimal adopted=new BigDecimal(text("SELECT fn_business_exact_divide_with_policy(?::numeric,1,'weight.kg-field','original kilograms',24,fn_business_precision_snapshot(),true)",raw));
        var source=new org.springframework.jdbc.datasource.SingleConnectionDataSource(db,true);
        var evidence=new com.uten.imp.common.numeric.BusinessNumericInputEvidenceService(
                new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(source),new com.fasterxml.jackson.databind.ObjectMapper());
        var kg=new com.uten.imp.application.port.BusinessNumericInputEvidencePort.Unit("WEIGHT","KG",null);
        UUID evidenceId=evidence.record(new com.uten.imp.application.port.BusinessNumericInputEvidencePort.Capture(
                "PURCHASE_RECEIPT",f.original(),f.oldLine(),"actualWeightKg","1",raw,kg,adopted,kg,
                Map.of("weight.kg-field",new BusinessPrecisionContext.Choice(24,"DOWN"))));
        exec("UPDATE purchase_receipt_items SET weight=? WHERE id=?",adopted,f.oldLine());
        lineage(f,null);
        choose("{\"version\":1,\"choices\":{\"weight.kg-field\":{\"scale\":0,\"rounding\":\"DOWN\"}}}",reviewer);
        cloneLine(f,f.newLine(),f.oldLine(),f.draft());immediate();
        assertThat(decimal(f.owner(),f.newLine(),"weight")).isEqualByComparingTo(adopted);
        assertThat(text("SELECT original_decimal FROM business_numeric_input_evidence WHERE id=?",evidenceId)).isEqualTo(raw.toPlainString());
        assertThat(text("SELECT precision_policy->'choices'->'weight.kg-field'->>'scale' FROM business_numeric_input_evidence WHERE id=?",evidenceId)).isEqualTo("24");
        assertThat(number("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_id=?",f.draft())).isZero();
    }

    private Fixture fixture(Owner owner,boolean total) throws Exception {
        choose(OLD_POLICY,actor);replica();UUID original=UUID.randomUUID(),draft=UUID.randomUUID(),old=UUID.randomUUID(),fresh=UUID.randomUUID();
        String oldNo=number(owner),newNo=number(owner);String header=owner.adapter().header().table();
        exec("INSERT INTO "+header+"(id,bill_no,bill_date,status,created_by,updated_by"+(owner.purchase()?",quantity_semantics":"")+") VALUES(?,?,?,-1,?,?"+(owner.purchase()?",'CHARGED_PLUS_GIFT_V1'":"")+")",original,oldNo,LocalDate.of(2026,11,5),actor,actor);
        if(total)exec("UPDATE "+header+" SET total_original=1,total_local=1 WHERE id=?",original);
        var cols=new ArrayList<>(List.of("id","bill_no","bill_date",owner.adapter().lines().parentColumn(),"line_no","goods_id","unit_id","unit_rate","qty","price","amount_original","amount_local","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","created_by","updated_by"));
        var args=new ArrayList<Object>(List.of(old,oldNo,LocalDate.of(2026,11,5),original,1,goods,unit,total?BigDecimal.ONE:Q,total?new BigDecimal("6"):Q,total?new BigDecimal("0.1666"):BigDecimal.ZERO,total?BigDecimal.ONE:BigDecimal.ZERO,total?BigDecimal.ONE:BigDecimal.ZERO,"CLONE-G-"+goods,"clone goods","MASTER_AT_APPROVAL",actor,actor));
        if(owner.purchase()){cols.addAll(List.of("quantity_semantics","gift_qty","charged_base_qty","gift_base_qty"));args.addAll(List.of("CHARGED_PLUS_GIFT_V1",total?BigDecimal.ZERO:Q,total?new BigDecimal("6"):BASE,total?BigDecimal.ZERO:BASE));}
        if(total){cols.add("total_amount_input");args.add(BigDecimal.ONE);}
        var bindings=new ArrayList<>(Collections.nCopies(args.size(),"?"));
        if(total){cols.add("reference_price_precision_policy");bindings.add("fn_business_precision_snapshot()");}
        exec("INSERT INTO "+owner.adapter().lines().table()+"("+String.join(",",cols)+") VALUES("+String.join(",",bindings)+")",args.toArray());
        DocumentUnapprovalPort.TableSnapshot spec=owner.adapter().header();
        var headerCols=new ArrayList<>(List.of("id","bill_no","status","created_at","updated_at","created_by","updated_by"));headerCols.addAll(spec.inputs());
        var values=new ArrayList<>(List.of("?","?","0","now()","now()","source.created_by","?"));values.addAll(spec.inputs().stream().map(c->"source."+c).toList());
        exec("INSERT INTO "+header+"("+String.join(",",headerCols)+") SELECT "+String.join(",",values)+" FROM "+header+" source WHERE id=?",draft,newNo,reviewer,original);
        return new Fixture(owner,original,draft,old,fresh,newNo);
    }
    private void lineage(Fixture f,String override) throws Exception {
        choose(OTHER_POLICY,reviewer);
        exec("INSERT INTO document_unapprovals(family,original_id,draft_id,draft_bill_no,request_key,reason,line_id_map,created_by) VALUES(?,?,?,?,?,?,CAST(? AS jsonb),?)",f.owner().adapter().family(),f.original(),f.draft(),f.draftNo(),"clone-native-"+UUID.randomUUID(),"retain actual original adoption",override==null?map(f):override,reviewer);
    }
    private static String map(Fixture f){return "{\""+f.oldLine()+"\":\""+f.newLine()+"\"}";}
    private void cloneLine(Fixture f,UUID id,UUID origin,UUID parent) throws Exception {
        var adapter=f.owner().adapter();assertThat(adapter.inheritsFrozenLineFacts()).isTrue();var spec=adapter.lines();
        var cols=new ArrayList<>(List.of("id",spec.parentColumn(),"created_at","updated_at","created_by","updated_by"));cols.addAll(spec.inputs());cols.addAll(List.of("bill_no","unapproval_source_item_id"));
        var values=new ArrayList<>(List.of("?","?","now()","now()","source.created_by","?"));values.addAll(spec.inputs().stream().map(c->"source."+c).toList());values.addAll(List.of("?","?"));
        exec("INSERT INTO "+spec.table()+"("+String.join(",",cols)+") SELECT "+String.join(",",values)+" FROM "+spec.table()+" source WHERE id=?",id,parent,reviewer,f.draftNo(),origin,f.oldLine());
    }
    private UUID actor(String role) throws Exception {
        UUID employee=UUID.randomUUID(),id=UUID.randomUUID();
        exec("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,?,'其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"CLONE-E-"+employee,"clone "+role+" "+employee);
        exec("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-not-used',false,'active')",id,employee,"clone-u-"+id);return id;
    }
    private void choose(String policy,UUID id) throws Exception {text("SELECT set_config('app.business_precision_choices',?,true)",policy);text("SELECT set_config('app.actor_id',?,true)",id.toString());}
    private void replica() throws Exception {exec("SET LOCAL session_replication_role=replica");}
    private void immediate() throws Exception {exec("SET CONSTRAINTS ALL IMMEDIATE");}
    private static String number(Owner o){return o.prefix+"20261105"+NUMBERS.incrementAndGet();}
    private String row(Owner o,UUID id) throws Exception{return text("SELECT to_jsonb(item)::text FROM "+o.adapter().lines().table()+" item WHERE id=?",id);}
    private BigDecimal decimal(Owner o,UUID id,String field) throws Exception {return new BigDecimal(text("SELECT "+field+" FROM "+o.adapter().lines().table()+" WHERE id=?",id));}
    private UUID uuid(String sql,Object...args) throws Exception{return UUID.fromString(text(sql,args));}
    private long number(String sql,Object...args) throws Exception{return Long.parseLong(text(sql,args));}
    private String text(String sql, Object... args) throws Exception {
        try (var q = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                q.setObject(i + 1, args[i]);
            }
            try (var r = q.executeQuery()) {
                assertThat(r.next()).isTrue();
                return r.getString(1);
            }
        }
    }
    private void exec(String sql, Object... args) throws Exception {
        try (var q = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                q.setObject(i + 1, args[i]);
            }
            q.execute();
        }
    }
    private void rejected(String state,Sql action) throws Exception {rejected(state,null,action);}
    private void rejected(String state,String message,Sql action) throws Exception {Savepoint point=db.setSavepoint();try{SQLException e=assertThrowsSql(action);assertThat(e.getSQLState()).isEqualTo(state);if(message!=null)assertThat(e.getMessage()).contains(message);}finally{db.rollback(point);db.releaseSavepoint(point);}}
    private static SQLException assertThrowsSql(Sql action){return Assertions.assertThrows(SQLException.class,action::run);}
    @FunctionalInterface interface Sql{void run() throws Exception;}
}
