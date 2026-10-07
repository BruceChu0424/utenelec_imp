package com.uten.imp.migration;

import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.callback.Callback;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.springframework.stereotype.Component;

import java.sql.SQLException;
import java.sql.Statement;
import java.util.Set;

/**
 * Preserves immutable migration bytes while safely rehearsing trigger-heavy upgrades.
 *
 * <p>V260, V263 and V273 were applied before their non-empty upgrade edge cases were
 * discovered. Their checksums are therefore immutable. For only those migration
 * transactions, deferred constraint triggers run immediately and V201's existing
 * transaction-local arrival-decision window authorizes migration-owned snapshot or
 * reference backfills. No trigger or constraint is disabled.</p>
 *
 * <p>V719/V720 also attempted to rename source labels already frozen in finance
 * approval snapshots. Only while those immutable migrations execute, an earlier
 * trigger skips a proven label-only rewrite of a commercially locked order item.
 * Existing labels and every other field remain unchanged; the commercial guard
 * itself is never replaced or disabled. The extra trigger is removed before the
 * migration transaction commits and rolls back with a failed migration.</p>
 */
@Component
public final class AppliedMigrationCompatibilityCallback implements Callback {

    private static final Set<String> GUARDED_MIGRATIONS = Set.of("260", "263", "273");
    private static final Set<String> LABEL_MIGRATIONS = Set.of("719", "720");
    private static final String USAGE_OWNER_MIGRATION = "815";

    @Override
    public boolean supports(Event event, Context context) {
        if (event != Event.BEFORE_EACH_MIGRATE && event != Event.AFTER_EACH_MIGRATE) {
            return false;
        }
        MigrationInfo migration = context.getMigrationInfo();
        return migration != null
                && migration.getVersion() != null
                && (USAGE_OWNER_MIGRATION.equals(migration.getVersion().getVersion())
                    || LABEL_MIGRATIONS.contains(migration.getVersion().getVersion())
                    || event == Event.BEFORE_EACH_MIGRATE
                        && GUARDED_MIGRATIONS.contains(migration.getVersion().getVersion()));
    }

    @Override
    public boolean canHandleInTransaction(Event event, Context context) {
        return true;
    }

    @Override
    public void handle(Event event, Context context) {
        try (Statement statement = context.getConnection().createStatement()) {
            statement.execute("SET CONSTRAINTS ALL IMMEDIATE");
            String version = context.getMigrationInfo().getVersion().getVersion();
            if (USAGE_OWNER_MIGRATION.equals(version)) {
                if (event == Event.BEFORE_EACH_MIGRATE) {
                    // V815's immutable interim table requires a user, while the
                    // authoritative log has always allowed system/unattributed calls.
                    // Only its unqualified backfill reads this connection-local view.
                    // Original rows stay in public unchanged; V820 backfills their
                    // NULL-owner bucket after making the aggregate identity nullable.
                    statement.execute("SELECT set_config('uten.compat_usage_search_path', current_setting('search_path'), true)");
                    // pg_temp must be implicit (searched first for relations),
                    // while unqualified CREATE TABLE still targets public.
                    // A role may otherwise explicitly list pg_temp after public.
                    statement.execute("SET LOCAL search_path = public");
                    statement.execute("""
                            CREATE TEMP VIEW ai_call_logs AS
                            SELECT * FROM public.ai_call_logs WHERE user_id IS NOT NULL
                            """);
                } else {
                    statement.execute("DROP VIEW pg_temp.ai_call_logs");
                    statement.execute("SELECT set_config('search_path', current_setting('uten.compat_usage_search_path'), true)");
                }
            } else if (LABEL_MIGRATIONS.contains(version)) {
                if (event == Event.BEFORE_EACH_MIGRATE) {
                    installFrozenLabelProtection(statement, version);
                } else {
                    removeFrozenLabelProtection(statement);
                }
            } else {
                statement.execute(
                        "SELECT set_config('app.procurement_arrival_decision', 'on', true)");
            }
        } catch (SQLException exception) {
            throw new FlywayException(
                    "Unable to prepare the immutable trigger-heavy migration transaction",
                    exception);
        }
    }

    private static void installFrozenLabelProtection(Statement statement, String version)
            throws SQLException {
        // CREATE (not OR REPLACE) fails closed if a previous/manual object exists.
        // The predicate must prove the exact immutable migration update, not merely
        // a WL-looking string. Returning NULL preserves the complete approved row
        // and does not manufacture a new audit event or row-version increment.
        statement.execute("""
                CREATE FUNCTION public.fn_preserve_frozen_analysis_label_migration()
                RETURNS trigger LANGUAGE plpgsql AS $compat$
                DECLARE
                    v_target text;
                    v_count bigint;
                BEGIN
                    IF TG_TABLE_SCHEMA <> 'public' OR TG_OP <> 'UPDATE'
                       OR NEW.source_doc_no IS NULL
                       OR NEW.source_doc_no !~ '^WL[0-9]{14}$' THEN
                        RETURN NEW;
                    END IF;
                    IF TG_TABLE_NAME = 'purchase_order_items' THEN
                        IF NOT procurement_order_commercial_locked('PURCHASE', OLD.order_id)
                           OR (to_jsonb(NEW) - ARRAY['source_doc_no','production_plan_no'])
                              IS DISTINCT FROM
                              (to_jsonb(OLD) - ARRAY['source_doc_no','production_plan_no'])
                           OR NEW.production_plan_no IS DISTINCT FROM NEW.source_doc_no
                           OR NOT (COALESCE(OLD.source_doc_no LIKE TG_ARGV[0] || '%', false)
                               OR COALESCE(OLD.production_plan_no LIKE TG_ARGV[0] || '%', false)) THEN
                            RETURN NEW;
                        END IF;
                        SELECT min(analysis.analysis_no), count(DISTINCT analysis.analysis_no)
                          INTO v_target, v_count
                          FROM purchase_order_item_sources source
                          JOIN purchase_request_items request_item
                            ON request_item.id = source.request_item_id
                          JOIN preplan_supply_actions action
                            ON action.external_document_type = 'PURCHASE_REQUEST'
                           AND action.external_document_id = request_item.request_id
                          JOIN production_material_analyses analysis
                            ON analysis.id = action.analysis_id
                         WHERE source.order_item_id = OLD.id;
                    ELSIF TG_TABLE_NAME = 'subcontract_order_items' THEN
                        IF NOT procurement_order_commercial_locked('SUBCONTRACT', OLD.order_id)
                           OR (to_jsonb(NEW) - 'source_doc_no')
                              IS DISTINCT FROM (to_jsonb(OLD) - 'source_doc_no')
                           OR NOT COALESCE(OLD.source_doc_no LIKE TG_ARGV[0] || '%', false) THEN
                            RETURN NEW;
                        END IF;
                        SELECT min(analysis.analysis_no), count(DISTINCT analysis.analysis_no)
                          INTO v_target, v_count
                          FROM subcontract_order_item_sources source
                          JOIN subcontract_application_items application_item
                            ON application_item.id = source.application_item_id
                          JOIN preplan_supply_actions action
                            ON action.external_document_type = 'SUBCONTRACT_APPLICATION'
                           AND action.external_document_id = application_item.application_id
                          JOIN production_material_analyses analysis
                            ON analysis.id = action.analysis_id
                         WHERE source.order_item_id = OLD.id;
                    ELSE
                        RETURN NEW;
                    END IF;
                    IF v_count = 1 AND v_target = NEW.source_doc_no THEN
                        RETURN NULL;
                    END IF;
                    RETURN NEW;
                END;
                $compat$
                """);
        String prefix = "719".equals(version) ? "计划前物料分析 " : "物料分析汇总 ";
        statement.execute("""
                CREATE TRIGGER aa_preserve_frozen_analysis_label_migration
                BEFORE UPDATE OF source_doc_no, production_plan_no ON public.purchase_order_items
                FOR EACH ROW EXECUTE FUNCTION
                public.fn_preserve_frozen_analysis_label_migration('%s')
                """.formatted(prefix));
        statement.execute("""
                CREATE TRIGGER aa_preserve_frozen_analysis_label_migration
                BEFORE UPDATE OF source_doc_no ON public.subcontract_order_items
                FOR EACH ROW EXECUTE FUNCTION
                public.fn_preserve_frozen_analysis_label_migration('%s')
                """.formatted(prefix));
    }

    private static void removeFrozenLabelProtection(Statement statement) throws SQLException {
        statement.execute("DROP TRIGGER aa_preserve_frozen_analysis_label_migration "
                + "ON public.purchase_order_items");
        statement.execute("DROP TRIGGER aa_preserve_frozen_analysis_label_migration "
                + "ON public.subcontract_order_items");
        statement.execute("DROP FUNCTION public.fn_preserve_frozen_analysis_label_migration()");
    }

    @Override
    public String getCallbackName() {
        return "applied-migration-trigger-compatibility";
    }
}
