package com.uten.imp.common.finance;

import com.uten.imp.support.MigratedProjectionSchema;
import java.math.BigDecimal;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;

/** A migrated shape with the actual owning adoption guard, independent of ORM defaults. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class DocumentQuantityAdoptionPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;static TransactionTemplate tx;
    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);tx=new TransactionTemplate(new DataSourceTransactionManager(source));
        MigratedProjectionSchema.createCurrentTables(db,"purchase_receipt_items","purchase_return_items","purchase_returns","subcontract_material_return_items","subcontract_receipt_items","purchase_order_items","business_numeric_input_evidence","document_unapprovals");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer","fn_business_exact_divide_with_policy","fn_business_precision_snapshot",
                "fn_financial_amount_is_exact","fn_document_quantity_to_base","fn_document_return_quantity_slice",
                "fn_unapproval_source_item","fn_unapproval_frozen_fields","fn_guard_document_quantity_adoption","fn_document_material_return_base","fn_validate_receipt_weight_adoption");
        for(String table:new String[]{"purchase_receipt_items","purchase_return_items","subcontract_material_return_items","subcontract_receipt_items","purchase_order_items"})
            db.execute("CREATE TRIGGER quantity_adoption BEFORE INSERT OR UPDATE ON "+table+" FOR EACH ROW EXECUTE FUNCTION fn_guard_document_quantity_adoption()");
        for(String table:new String[]{"purchase_receipt_items","subcontract_receipt_items"})
            db.execute("CREATE CONSTRAINT TRIGGER weight_adoption AFTER INSERT OR UPDATE ON "+table+" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_validate_receipt_weight_adoption()");
    }
    @AfterAll static void stop(){PG.stop();}
    @Test void actualSavedOperandsRequireChoiceAndLaterPriceEditsKeepTheirFrozenProof(){
        UUID id=UUID.randomUUID(),unit=UUID.randomUUID();
        assertThatThrownBy(()->insertMaterial(id,unit,"0.1","0.123456789012345678901234")).rootCause().hasMessageMatching("(?s).*UTEN_PRECISION_REQUIRED.*");
        tx.executeWithoutResult(status->{choice("24","DOWN");insertMaterial(id,unit,"0.1","0.123456789012345678901234");});
        assertThat(number("adopted_base_qty",id)).isEqualByComparingTo("0.012345678901234567890123");
        String policy=db.queryForObject("SELECT quantity_precision_policy::text FROM subcontract_material_return_items WHERE id=?",String.class,id);
        tx.executeWithoutResult(status->{choice("0","HALF_UP");db.update("UPDATE subcontract_material_return_items SET price=17 WHERE id=?",id);});
        assertThat(db.queryForObject("SELECT quantity_precision_policy::text FROM subcontract_material_return_items WHERE id=?",String.class,id)).isEqualTo(policy);
        assertThat(db.queryForObject("SELECT fn_document_material_return_base(i) FROM subcontract_material_return_items i WHERE id=?",BigDecimal.class,id)).isEqualByComparingTo(number("adopted_base_qty",id));
    }
    @Test void newRowsCannotClaimLegacyAndFiniteNativeInputsDoNotRequireAChoice(){
        UUID id=UUID.randomUUID();insertMaterial(id,UUID.randomUUID(),"0.000000000000000000000001","1");
        assertThat(number("adopted_base_qty",id)).isEqualByComparingTo("1e-24");
        assertThat(db.queryForObject("SELECT quantity_adoption_version FROM subcontract_material_return_items WHERE id=?",Integer.class,id)).isEqualTo(2);
        assertThatThrownBy(()->db.update("INSERT INTO subcontract_material_return_items(id,unit_id,qty,unit_rate,quantity_adoption_version) VALUES(?,?,1,1,1)",UUID.randomUUID(),UUID.randomUUID())).rootCause().hasMessageMatching("(?s).*current exact operation proof.*");
        assertThatThrownBy(()->db.update("UPDATE subcontract_material_return_items SET adopted_base_qty=2 WHERE id=?",id)).rootCause().hasMessageMatching("(?s).*precision evidence cannot.*|(?s).*adoption.*");
        // The owning trigger derives the true product rather than accepting a supplied derived value.
        assertThat(number("adopted_base_qty",id)).isEqualByComparingTo("1e-24");
    }
    @Test void chargedAndGiftMustMatchTheSamePhysicalAdoption(){
        UUID id=UUID.randomUUID();
        tx.executeWithoutResult(status->{choice("24","HALF_UP");db.update("""
            INSERT INTO purchase_receipt_items(id,unit_id,qty,gift_qty,unit_rate,quantity_semantics,charged_base_qty,gift_base_qty)
            VALUES(?,?,.1,.2,.123456789012345678901234,'CHARGED_PLUS_GIFT_V1',.012345678901234567890123,.024691357802469135780247)
            """,id,UUID.randomUUID());});
        assertThat(db.queryForObject("SELECT charged_base_qty+gift_base_qty FROM purchase_receipt_items WHERE id=?",BigDecimal.class,id)).isEqualByComparingTo(".037037036703703703670370");
        assertThatThrownBy(()->db.update("UPDATE purchase_receipt_items SET charged_base_qty=2 WHERE id=?",id)).rootCause().hasMessageMatching("(?s).*UTEN_PRECISION_REQUIRED.*|(?s).*actual quantity adoption.*");
    }
    @Test void sourceTrancheFinalReturnUsesActualRemainingBasicQuantity(){
        UUID source=UUID.randomUUID(),unit=UUID.randomUUID();
        db.update("INSERT INTO purchase_receipt_items(id,unit_id,qty,gift_qty,unit_rate,quantity_semantics,charged_base_qty,gift_base_qty) VALUES(?,?,3,0,1,'CHARGED_PLUS_GIFT_V1',3,0)",source,unit);
        // This independent source-slice oracle retains actual historical allocations.
        assertThat(db.queryForObject("SELECT fn_document_return_quantity_slice(1,3,1,2,.6667,'{\"version\":1,\"choices\":{}}'::jsonb)",BigDecimal.class)).isEqualByComparingTo(".3333");
        assertThatThrownBy(()->db.queryForObject("SELECT fn_document_return_quantity_slice(1,3,1,0,0,'{\"version\":1,\"choices\":{}}'::jsonb)",BigDecimal.class)).rootCause().hasMessageMatching("(?s).*UTEN_PRECISION_REQUIRED.*");
    }
    @Test void orderBudgetAndSubcontractReceiptUseTheirSavedAdoptionAfterHeaderChoiceChanges(){
        UUID order=UUID.randomUUID(),receipt=UUID.randomUUID(),unit=UUID.randomUUID();
        tx.executeWithoutResult(status->{choice("24","HALF_UP");
            db.update("INSERT INTO purchase_order_items(id,unit_id,qty,gift_qty,unit_rate,quantity_semantics) VALUES(?,?,.1,.2,.123456789012345678901234,'CHARGED_PLUS_GIFT_V1')",order,unit);
            db.update("INSERT INTO subcontract_receipt_items(id,unit_id,qty,unit_rate) VALUES(?,?,.1,.123456789012345678901234)",receipt,unit);
        });
        BigDecimal budget=db.queryForObject("SELECT gift_base_qty FROM purchase_order_items WHERE id=?",BigDecimal.class,order);
        BigDecimal adopted=db.queryForObject("SELECT adopted_base_qty FROM subcontract_receipt_items WHERE id=?",BigDecimal.class,receipt);
        tx.executeWithoutResult(status->{choice("0","DOWN");db.update("UPDATE purchase_order_items SET received_qty=.01 WHERE id=?",order);db.update("UPDATE subcontract_receipt_items SET amount_local=17 WHERE id=?",receipt);});
        assertThat(db.queryForObject("SELECT gift_base_qty FROM purchase_order_items WHERE id=?",BigDecimal.class,order)).isEqualByComparingTo(budget);
        assertThat(db.queryForObject("SELECT adopted_base_qty FROM subcontract_receipt_items WHERE id=?",BigDecimal.class,receipt)).isEqualByComparingTo(adopted);
        assertThat(budget).isEqualByComparingTo(".024691357802469135780247");
    }
    @Test void aSourceTrancheAdoptionMayDifferFromTheSavedRawProductButIsProvenByActualSourceAndPrior(){
        UUID source=UUID.randomUUID(),unit=UUID.randomUUID(),doc=UUID.randomUUID(),item=UUID.randomUUID();
        tx.executeWithoutResult(status->{choice("24","DOWN");
            db.update("INSERT INTO purchase_receipt_items(id,unit_id,qty,gift_qty,unit_rate,quantity_semantics,charged_base_qty,gift_base_qty) VALUES(?,?,.3,0,.123456789012345678901234,'CHARGED_PLUS_GIFT_V1',.037037036703703703670370,0)",source,unit);
        });
        db.update("INSERT INTO purchase_returns(id,status) VALUES(?,0)",doc);
        tx.executeWithoutResult(status->{choice("23","HALF_UP");
            db.update("INSERT INTO purchase_return_items(id,return_id,receipt_item_id,unit_id,qty,gift_qty,unit_rate,quantity_semantics,charged_base_qty,gift_base_qty) VALUES(?,?,?,?,.1,0,.123456789012345678901234,'CHARGED_PLUS_GIFT_V1',.01234567890123456789012,0)",item,doc,source,unit);
        });
        tx.executeWithoutResult(status->{db.queryForObject("SELECT set_config('app.business_precision_choices',?,true)",String.class,"{\"version\":1,\"choices\":{\"procurement.return.base-quantity\":{\"scale\":24,\"rounding\":\"DOWN\"}}}");
            db.update("UPDATE purchase_return_items SET charged_base_qty=.012345678901234567890123 WHERE id=?",item);
        });
        assertThat(db.queryForObject("SELECT quantity_source_proof->>'kind' FROM purchase_return_items WHERE id=?",String.class,item)).isEqualTo("SOURCE_RECEIPT");
        assertThat(db.queryForObject("SELECT charged_base_qty FROM purchase_return_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo(".012345678901234567890123");
        assertThatThrownBy(()->db.update("UPDATE purchase_return_items SET charged_base_qty=.03 WHERE id=?",item)).isInstanceOf(RuntimeException.class);
    }
    @Test void receiptWeightMustMatchSameActionOriginalKilogramsAndFrozenChoice(){
        UUID document=UUID.randomUUID(),item=UUID.randomUUID(),unit=UUID.randomUUID();
        tx.executeWithoutResult(status->{
            String json="{\"kind\":\"WEIGHT\",\"code\":\"KG\",\"referenceId\":null}";
            db.update("INSERT INTO business_numeric_input_evidence(id,owner_kind,owner_id,source_row_id,field_key,owner_version,source_action_id,original_decimal,original_unit,recorded_decimal,recorded_unit,precision_policy) VALUES(?,'PURCHASE_RECEIPT',?,?,'actualWeightKg','1',pg_current_xact_id()::text,'.1234567890123456789012345',?::jsonb,'.123456789012345678901235',?::jsonb,'{\"version\":1,\"choices\":{\"weight.kg-field\":{\"scale\":24,\"rounding\":\"HALF_UP\"}}}'::jsonb)",UUID.randomUUID(),document,item,json,json);
            db.update("INSERT INTO purchase_receipt_items(id,receipt_id,unit_id,qty,gift_qty,unit_rate,quantity_semantics,charged_base_qty,gift_base_qty,weight) VALUES(?,?,?,1,0,1,'LEGACY_RECORDED',1,0,.123456789012345678901235)",item,document,unit);
        });
        assertThat(db.queryForObject("SELECT weight FROM purchase_receipt_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo(".123456789012345678901235");
        assertThatThrownBy(()->db.update("UPDATE purchase_receipt_items SET weight=.1 WHERE id=?",item)).isInstanceOf(RuntimeException.class);
        assertThat(db.queryForObject("SELECT weight FROM purchase_receipt_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo(".123456789012345678901235");
    }
    static void choice(String scale,String mode){db.queryForObject("SELECT set_config('app.business_precision_choices',?,true)",String.class,"{\"version\":1,\"choices\":{\"quantity.to-base\":{\"scale\":"+scale+",\"rounding\":\""+mode+"\"}}}");}
    static void insertMaterial(UUID id,UUID unit,String qty,String rate){db.update("INSERT INTO subcontract_material_return_items(id,unit_id,qty,unit_rate) VALUES(?,?,?,?)",id,unit,new BigDecimal(qty),new BigDecimal(rate));}
    static BigDecimal number(String column,UUID id){return db.queryForObject("SELECT "+column+" FROM subcontract_material_return_items WHERE id=?",BigDecimal.class,id);}
}
