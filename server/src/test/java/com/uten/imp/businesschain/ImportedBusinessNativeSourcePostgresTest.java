package com.uten.imp.businesschain;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.history.ImportedBusinessDocumentScope;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.master.goods.GoodsRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Field;
import java.util.Locale;
import java.util.Set;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Real schema and source-set equivalence, sharing the streaming HTTP test's migrated database. */
class ImportedBusinessNativeSourcePostgresTest extends AuthSessionPostgresTestSupport {
    @MockitoSpyBean GoodsRepository goodsRepository;
    @Autowired DocNumberService numbers;

    @Test
    @Transactional
    void nonemptyNativeAndZeroMinusOneInheritedRowsRetainTheAuthoritativeGraph() {
        // The migrated database owner is the same maintenance identity accepted
        // by the original import guard. Never spoof app.legacy_import or disable a trigger.
        assertThat(jdbc.queryForObject("SELECT fn_imported_business_document_maintenance_allowed()",Boolean.class)).isTrue();
        String tag=("ORIGIN-"+UUID.randomUUID()).toUpperCase(Locale.ROOT);
        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID();
        jdbc.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')",unit,tag+"-UNIT",tag);
        long sequence=jdbc.queryForObject("SELECT COALESCE(max(code_sequence),0)+1 FROM goods",Long.class);
        jdbc.update("INSERT INTO goods(id,code,name,status,unit_id,code_sequence,auto_created) VALUES(?,?,?,'使用',?,?,false)",goods,tag,tag,unit,sequence);
        UUID nativeHeader=UUID.randomUUID(),zeroHeader=UUID.randomUUID(),minusHeader=UUID.randomUUID();
        UUID nativeItem=UUID.randomUUID(),zeroInherited=UUID.randomUUID(),minusInherited=UUID.randomUUID();
        var headers=List.of(nativeHeader,zeroHeader,minusHeader);
        var items=List.of(nativeItem,zeroInherited,minusInherited);
        var billDate=BusinessTime.today();
        for(int index=0;index<items.size();index++) {
            Integer legacy=switch(index){case 1->0;case 2->-1;default->null;};
            String billNo=numbers.nextNumber(DocNumberPrefix.PURCHASE_REQUEST);
            jdbc.update("INSERT INTO purchase_requests(id,legacy_id,bill_no,bill_date) VALUES(?,?,?,?)",
                    headers.get(index),legacy,billNo,billDate);
            jdbc.update("""
                    INSERT INTO purchase_request_items(id,request_id,bill_no,bill_date,line_no,goods_id,unit_id,qty,
                        goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                    VALUES(?,?,?,?,1,?,?,1,?,?,'MASTER_AT_SAVE')
                    """,items.get(index),headers.get(index),billNo,billDate,goods,unit,tag,tag);
        }
        assertThat(jdbc.queryForList("SELECT id FROM purchase_requests WHERE id IN (?,?,?)",UUID.class,nativeHeader,zeroHeader,minusHeader)).hasSize(3);
        assertThat(jdbc.queryForList("SELECT id FROM purchase_request_items WHERE id IN (?,?,?) AND legacy_id IS NULL",UUID.class,nativeItem,zeroInherited,minusInherited)).hasSize(3);
        for(String table:List.of("purchase_requests","purchase_request_items")) {
            var ids=table.equals("purchase_requests")?headers:items;
            var original=jdbc.queryForList("SELECT id FROM "+originalSource(table)+" source WHERE id IN (?,?,?)",UUID.class,ids.toArray());
            var optimized=jdbc.queryForList("SELECT id FROM "+ImportedBusinessDocumentScope.nativeTable(table)+" source WHERE id IN (?,?,?)",UUID.class,ids.toArray());
            assertThat(original).as("nonempty original native set: %s",table).containsExactly(ids.getFirst());
            assertThat(optimized).as("the registry carries the inherited-source verdict: %s",table).containsExactlyElementsOf(original);
            // Maintenance-identity inserts registered their own verdicts through the V1120 guard.
            assertThat(jdbc.queryForList("SELECT row_id FROM imported_document_registry WHERE table_name=? AND row_id IN (?,?,?)",
                    UUID.class,table,ids.get(0),ids.get(1),ids.get(2))).containsExactlyInAnyOrder(ids.get(1),ids.get(2));
        }
        for(UUID inherited:List.of(zeroInherited,minusInherited)) {
            assertThat(jdbc.queryForObject("SELECT fn_imported_business_document_row('purchase_request_items',to_jsonb(item)) FROM purchase_request_items item WHERE id=?",Boolean.class,inherited))
                    .as("legacy-null child inherits its original 0/-1 source").isTrue();
        }
        // Spring rolls this entire graph back, including summaries/audit/import evidence.
    }

    @Test
    @Transactional
    void runOnlyTypedPhysicalRowIsNeverReinterpretedAsNative() throws Exception {
        UUID imported=UUID.randomUUID(),nativeId=UUID.randomUUID(),run=UUID.randomUUID();
        // V627 requires immutable import evidence to persist receipt rows. A
        // read-only typed physical-row value tests the run-only predicate without
        // forging that evidence or bypassing its production insertion guard.
        String rows=objectMapper.writeValueAsString(List.of(
                java.util.Map.of("id",imported.toString(),"legacy_import_run_id",run.toString()),
                java.util.Map.of("id",nativeId.toString())));
        String source="jsonb_populate_recordset(NULL::public.purchase_receipts,?::jsonb) archive_origin";
        assertThat(jdbc.queryForObject("SELECT count(*) FROM "+source,Long.class,rows)).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT fn_imported_business_document_row('purchase_receipts',to_jsonb(archive_origin)) FROM "+source+" WHERE id=?",Boolean.class,rows,imported)).isTrue();
        String original="NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document_row('purchase_receipts',to_jsonb(archive_origin))";
        var oldRows=jdbc.queryForList("SELECT id FROM "+source+" WHERE "+original,UUID.class,rows);
        var newRows=jdbc.queryForList("SELECT id FROM "+source+" WHERE "+ImportedBusinessDocumentScope.nativePredicate("purchase_receipts","archive_origin"),UUID.class,rows);
        assertThat(oldRows).containsExactly(nativeId);
        assertThat(newRows).containsExactlyElementsOf(oldRows);
    }

    /** The pre-V1120 read: JSON direct keys plus the pure V933 walk, never the registry. */
    private static String originalSource(String table) {
        return "(SELECT * FROM "+table+" archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL "
                +"AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL "
                +"AND NOT fn_imported_business_document_row_internal('"+table+"',to_jsonb(archive_origin),ARRAY[]::text[]))";
    }

    @Test
    void everyOwnedNativeSourceKeepsItsExactOriginalRowsAndRealTypedColumns() throws Exception {
        Field sources=ImportedBusinessDocumentScope.class.getDeclaredField("NATIVE_TABLES");
        sources.setAccessible(true);
        @SuppressWarnings("unchecked") Set<String> tables=(Set<String>)sources.get(null);
        assertThat(tables).hasSize(32);
        for(String table:tables) {
            String optimized=ImportedBusinessDocumentScope.nativeTable(table);
            String original=originalSource(table);
            // EXCEPT compares actual identities, not just equal counts: registry predicate ≡ authority.
            Long difference=jdbc.queryForObject("SELECT count(*) FROM ((SELECT id FROM "+original
                    +" old_source EXCEPT SELECT id FROM "+optimized+" new_source) UNION ALL (SELECT id FROM "
                    +optimized+" new_source EXCEPT SELECT id FROM "+original+" old_source)) delta",Long.class);
            assertThat(difference).as(table).isZero();
            for(String column:Set.of("legacy_id","legacy_import_run_id")) {
                var types=jdbc.queryForList("SELECT data_type FROM information_schema.columns "
                        +"WHERE table_schema='public' AND table_name=? AND column_name=?",String.class,table,column);
                assertThat(optimized.contains("archive_origin."+column+" IS NULL"))
                        .as(table+"."+column).isEqualTo(!types.isEmpty());
                if(!types.isEmpty()) assertThat(types.getFirst()).isIn("integer","uuid");
            }
        }
    }

    @Test
    @Transactional
    void everyGuardedUuidRowIsRegisteredExactlyWhenTheAuthorityClassifiesItImported() {
        // A keyed import, an inherited child and an ordinary native row in one real chain.
        UUID imported=UUID.randomUUID(),inherited=UUID.randomUUID(),nativeHeader=UUID.randomUUID();
        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID();String tag=("REG-"+UUID.randomUUID()).toUpperCase(Locale.ROOT);
        jdbc.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')",unit,tag+"-UNIT",tag);
        long sequence=jdbc.queryForObject("SELECT COALESCE(max(code_sequence),0)+1 FROM goods",Long.class);
        jdbc.update("INSERT INTO goods(id,code,name,status,unit_id,code_sequence,auto_created) VALUES(?,?,?,'使用',?,?,false)",goods,tag,tag,unit,sequence);
        var billDate=BusinessTime.today();
        for(UUID header:List.of(imported,nativeHeader)) {
            jdbc.update("INSERT INTO purchase_requests(id,legacy_id,bill_no,bill_date) VALUES(?,?,?,?)",
                    header,header.equals(imported)?7:null,numbers.nextNumber(DocNumberPrefix.PURCHASE_REQUEST),billDate);
        }
        jdbc.update("""
                INSERT INTO purchase_request_items(id,request_id,bill_no,bill_date,line_no,goods_id,unit_id,qty,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                VALUES(?,?,'R',?,1,?,?,1,?,?,'MASTER_AT_SAVE')
                """,inherited,imported,billDate,goods,unit,tag,tag);
        var guarded=jdbc.queryForList("""
                SELECT relation.relname::text FROM pg_trigger guard JOIN pg_class relation ON relation.oid=guard.tgrelid
                JOIN pg_namespace ns ON ns.oid=relation.relnamespace
                JOIN pg_attribute identity ON identity.attrelid=relation.oid AND identity.attname='id'
                     AND NOT identity.attisdropped AND identity.atttypid='uuid'::regtype
                WHERE ns.nspname='public' AND guard.tgname='trg_00_imported_business_archive_only' AND NOT guard.tgisinternal
                ORDER BY 1
                """,String.class);
        assertThat(guarded).hasSizeGreaterThan(200).contains("purchase_requests","purchase_request_items","stock_movements");
        for(String table:guarded) {
            Long difference=jdbc.queryForObject("""
                    SELECT count(*) FROM public.%1$s row_image
                    WHERE fn_imported_business_document_row_internal('%1$s',to_jsonb(row_image),ARRAY[]::text[])
                       <> EXISTS(SELECT 1 FROM imported_document_registry registry
                                 WHERE registry.table_name='%1$s' AND registry.row_id=row_image.id)
                    """.formatted(table),Long.class);
            assertThat(difference).as("registry verdict of %s",table).isZero();
        }
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM imported_document_registry registry
                WHERE NOT EXISTS(SELECT 1 FROM pg_trigger guard WHERE guard.tgrelid=to_regclass('public.'||registry.table_name)
                  AND guard.tgname='trg_00_imported_business_archive_only' AND NOT guard.tgisinternal)
                """,Long.class)).as("no registration outside a guarded relation").isZero();
        assertThat(jdbc.queryForList("SELECT row_id FROM imported_document_registry WHERE row_id IN (?,?,?)",
                UUID.class,imported,inherited,nativeHeader)).containsExactlyInAnyOrder(imported,inherited);
    }
}
