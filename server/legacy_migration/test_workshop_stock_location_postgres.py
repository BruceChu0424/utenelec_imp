"""Execute the reviewed ETL SQL in a disposable, network-none PG16.15 fixture.

This module does not connect to a pre-existing PostgreSQL server. Its native
fixture contract is completed against the sibling consumer SQL, not a duplicate
Python implementation of the routing decisions.
"""
from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import unittest
import uuid


HERE = Path(__file__).resolve().parent
OUTPUT = HERE.parent / "target" / "workshop-stock-location-native"
HELPER = HERE / "reviewed_workshop_stock_location.sql"
IMAGE = "postgres:16.15"
MIGRATIONS = HERE.parent / "src" / "main" / "resources" / "db" / "migration"
PRODUCTS = (
    (65919, "GD2056", "B款暗装轨道E极铜条（90型）", "8"),
    (65920, "GD2057", "B款暗装轨道LN极铜条（90型  磨床切割）", "15"),
    (65921, "GD2058", "B款暗装轨道PVC线槽（90型）", "8"),
    (65923, "GD2060", "B款暗装铝合金轨道90型（铣床加工）", "0"),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class OwnedPostgres:
    """One exact owned container; no host/port arguments or reusable CID input."""

    def __init__(self):
        self.token = uuid.uuid4().hex
        self.label = "uten.workshop-stock-location-fixture"
        self.cid = None
        self.evidence = {"image": IMAGE, "network": "none", "published_ports": False,
                         "ownership_label": self.label, "ownership_token": self.token,
                         "existing_database_or_company_accessed": False}

    @staticmethod
    def docker(*args, input_text=None, check=True):
        result = subprocess.run(["docker", *args], input=input_text, capture_output=True,
                                text=True, encoding="utf-8", timeout=60)
        if check and result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result

    def start(self):
        self.cid = self.docker(
            "run", "--detach", "--network", "none", "--tmpfs",
            "/var/lib/postgresql/data:rw,size=512m", "--label", self.label + "=" + self.token,
            "--env", "POSTGRES_PASSWORD=owned-workshop-fixture-only", "--env",
            "POSTGRES_INITDB_ARGS=--auth-local=trust --auth-host=reject", IMAGE).stdout.strip()
        self.evidence["container_id"] = self.cid
        self._verify_owned()
        for _ in range(150):
            result = self.docker("exec", self.cid, "pg_isready", "-U", "postgres", check=False)
            if result.returncode == 0 and self.docker("exec", self.cid, "cat", "/proc/1/comm").stdout.strip() == "postgres":
                break
            time.sleep(.1)
        else:
            raise AssertionError("owned PostgreSQL did not become ready")
        identity = json.loads(self.sql("postgres", """
            SELECT jsonb_build_object('version',current_setting('server_version'),
                'sid',(SELECT system_identifier::text FROM pg_control_system()),
                'socket',inet_server_addr() IS NULL);
            """).stdout)
        assert identity["version"].startswith("16.15") and identity["socket"] is True
        self.evidence["actual_identity"] = identity
        self.sql("postgres", "CREATE ROLE workshop_fixture_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;")

    def _verify_owned(self):
        if not self.cid or len(self.cid) != 64:
            raise AssertionError("missing exact owned CID")
        inspect = json.loads(self.docker("inspect", self.cid).stdout)[0]
        assert inspect["Id"] == self.cid
        assert inspect["Config"]["Labels"].get(self.label) == self.token
        assert inspect["HostConfig"]["NetworkMode"] == "none"
        assert not inspect["HostConfig"].get("PortBindings")
        self.evidence["image_id"] = inspect["Image"]

    def sql(self, database, text, *, owner=False, check=True):
        return self.docker("exec", "-i", self.cid, "psql", "-X", "-qAt",
                           "-v", "ON_ERROR_STOP=1", "-U",
                           "workshop_fixture_owner" if owner else "postgres", "-d", database,
                           input_text=text, check=check)

    def copy_text(self, relative_name, value):
        if "/" in relative_name or "\\" in relative_name:
            raise ValueError("fixture files must have a single exact filename")
        self.docker("exec", "-i", self.cid, "sh", "-c", 'cat > "$1"', "sh",
                    "/tmp/" + relative_name, input_text=value)

    def close(self):
        if self.cid:
            self._verify_owned()
            result = self.docker("rm", "--force", self.cid)
            self.evidence["owned_container_and_tmpfs_removed"] = result.returncode == 0
            self.evidence["cleanup_exact_cid_and_label_verified"] = True


def csv_text(headers, rows):
    import io
    stream = io.StringIO(newline="")
    writer = csv.writer(stream, delimiter="|", lineterminator="\n")
    writer.writerow(headers)
    writer.writerows(rows)
    return stream.getvalue()


def function_ddl(filename, name):
    source = (MIGRATIONS / filename).read_text(encoding="utf-8")
    match = re.search(r"CREATE(?: OR REPLACE)? FUNCTION (?:public\.)?" + re.escape(name)
                      + r"\(.*?\$\$;", source, flags=re.S)
    if not match:
        raise AssertionError("real migration function missing: " + name)
    return match.group(0)


def ordinary_target_guard_sql(source):
    tag = "$ordinary_stock_warehouse_targets$"
    start = source.index("DO " + tag)
    end = source.index(tag + ";", start + len(tag) + 3) + len(tag) + 1
    return source[start:end]


REVIEW_HEADERS = ["goods_legacy_id", "goods_code", "goods_name", "original_owning_warehouse",
                  "workshop_code", "workshop_name", "owning_warehouse", "resolution", "source_file", "source_row"]
CROSSWALK_HEADERS = ["goods_legacy_id", "goods_code", "goods_name", "workshop_code", "bin_warehouse_id", "authority_sha256"]
AUTHORITY_HEADERS = ["format", "approved", "target_database", "target_database_oid", "target_sid", "workshop_code",
                     "workshop_department_id", "bin_warehouse_id", "bin_row_sha256", "warehouse_row_sha256",
                     "department_row_sha256", "opened_by", "opened_at", "source_warehouse_id", "bin_row_version",
                     "authority_sha256", "snapshot_sha256", "review_sha256"]


class WorkshopStockLocationPostgresTest(unittest.TestCase):
    """Case implementations are pinned to the real sibling SQL's stage interface."""

    @classmethod
    def setUpClass(cls):
        if not HELPER.is_file():
            raise RuntimeError("real reviewed_workshop_stock_location.sql is required before native execution")
        OUTPUT.mkdir(parents=True, exist_ok=True)
        cls.fixture = OwnedPostgres()
        cls.results = []
        try:
            cls.fixture.start()
        except BaseException:
            cls.fixture.close()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.fixture.close()
        result = {"format": "reviewed-workshop-stock-location-native-v1",
                  "script_sha256": sha256(Path(__file__)), "helper_sha256": sha256(HELPER),
                  "fixture": cls.fixture.evidence, "cases": cls.results,
                  "migration_inputs": {name: sha256(MIGRATIONS / name) for name in (
                      "V613__operational_warehouse_leaf_identity.sql", "V800__warehouse_single_main_master_shape.sql",
                      "V802__workshop_bin_opening_single_source.sql", "V926__imported_business_documents_archive_only.sql",
                      "V743__warehouse_weight_ledger_and_learning.sql")},
                  "full_schema_migrated": False,
                  "workshop_bins_actual_migration_columns": 8,
                  "actual_business_database_accessed": False}
        (OUTPUT / "receipt.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    def setUp(self):
        self.database = "ws_native_" + uuid.uuid4().hex
        self.fixture.sql("postgres", "CREATE DATABASE " + self.database + " OWNER workshop_fixture_owner;")
        self.fixture.sql(self.database, "GRANT EXECUTE ON FUNCTION pg_control_system() TO workshop_fixture_owner;")
        self.ids = {name: str(uuid.uuid4()) for name in ("production", "workshop", "other_workshop", "root", "ordinary", "bin", "extra", "actor", "unit")}
        ids = self.ids
        table_source = (MIGRATIONS / "V802__workshop_bin_opening_single_source.sql").read_text(encoding="utf-8")
        bin_table = re.search(r"CREATE TABLE workshop_bins \(.*?\n\);", table_source, flags=re.S).group(0)
        schema = """
            CREATE TABLE users(id uuid PRIMARY KEY);
            CREATE TABLE departments(id uuid PRIMARY KEY,code text,parent_id uuid REFERENCES departments(id),is_deleted boolean NOT NULL DEFAULT false);
            CREATE TABLE units(id uuid PRIMARY KEY,name text,is_deleted boolean NOT NULL DEFAULT false);
            CREATE TABLE warehouses(id uuid PRIMARY KEY,legacy_id int UNIQUE,code text,name text,parent_id uuid REFERENCES warehouses(id),
                status text,is_line_side boolean NOT NULL DEFAULT false,is_accountable boolean NOT NULL DEFAULT true,
                is_defective boolean NOT NULL DEFAULT false,is_deleted boolean NOT NULL DEFAULT false,workshop_department_id uuid REFERENCES departments(id));
            CREATE TABLE goods(id uuid PRIMARY KEY,legacy_id int UNIQUE,code text,name text,is_deleted boolean NOT NULL DEFAULT false,
                owning_warehouse_id uuid REFERENCES warehouses(id),owning_workshop_department_id uuid REFERENCES departments(id),unit_id uuid REFERENCES units(id));
            CREATE TABLE workshop_material_settings(workshop_department_id uuid PRIMARY KEY REFERENCES departments(id),periodic_enabled boolean NOT NULL DEFAULT false);
            CREATE TABLE source_stock_facts(id uuid PRIMARY KEY,stock_legacy int,goods_legacy int,year int,qty numeric,fact_qty numeric,amount numeric,raw_source jsonb);
            CREATE TABLE transaction_effect(n int);
            INSERT INTO transaction_effect VALUES(0);
            CREATE TABLE colors(id uuid PRIMARY KEY,legacy_id int UNIQUE);
            CREATE TABLE unit_measurement_profiles(unit_id uuid PRIMARY KEY,mass_unit_code text);
            CREATE TABLE stock_balances(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),warehouse_id uuid,goods_id uuid,color_id uuid,
                qty numeric,amount_local numeric,weight numeric,weight_estimated boolean,last_movement_date timestamptz,updated_at timestamptz,
                UNIQUE NULLS NOT DISTINCT(warehouse_id,goods_id,color_id));
        """ + bin_table
        schema += "\n" + "\n".join(function_ddl(filename, name) for filename, name in (
            ("V613__operational_warehouse_leaf_identity.sql", "fn_warehouse_is_operational_leaf"),
            ("V613__operational_warehouse_leaf_identity.sql", "fn_warehouse_is_active_accounting_leaf"),
            ("V800__warehouse_single_main_master_shape.sql", "fn_warehouse_root_id"),
            ("V800__warehouse_single_main_master_shape.sql", "fn_warehouse_is_good_stock_leaf"),
            ("V743__warehouse_weight_ledger_and_learning.sql", "fn_weight_unit_kg_factor"),
            ("V926__imported_business_documents_archive_only.sql", "fn_imported_business_document_maintenance_allowed")))
        schema += f"""
            INSERT INTO users VALUES('{ids['actor']}');
            INSERT INTO departments VALUES('{ids['production']}','DEPT_PROD',NULL,false),
                ('{ids['workshop']}','WS_WJTZ','{ids['production']}',false),
                ('{ids['other_workshop']}','WS_OTHER','{ids['production']}',false);
            INSERT INTO units VALUES('{ids['unit']}','条',false);
            INSERT INTO warehouses(id,legacy_id,code,name,status) VALUES('{ids['root']}',132,'001','主仓库','使用');
            INSERT INTO warehouses(id,legacy_id,code,name,parent_id,status) VALUES('{ids['ordinary']}',134,'WH_TRACK','轨道车间仓库','{ids['root']}','使用');
            INSERT INTO warehouses(id,code,name,parent_id,status,is_line_side,workshop_department_id)
                VALUES('{ids['bin']}','LS_WJTZ','五金铜铸内料仓','{ids['root']}','使用',true,'{ids['workshop']}');
            INSERT INTO workshop_bins(workshop_department_id,bin_warehouse_id,source_warehouse_id,opened_by,opened_at,updated_by,updated_at,row_version)
                VALUES('{ids['workshop']}','{ids['bin']}','{ids['ordinary']}','{ids['actor']}',TIMESTAMPTZ '2026-01-02 08:00:00+08',
                    '{ids['actor']}',TIMESTAMPTZ '2026-01-02 08:00:00+08',3);
            INSERT INTO workshop_material_settings VALUES('{ids['workshop']}',false);
        """
        for index, (legacy, code, name, qty) in enumerate(PRODUCTS):
            gid, source = uuid.uuid4(), uuid.uuid4()
            schema += f"""
                INSERT INTO goods VALUES('{gid}',{legacy},'{code}','{name}',false,NULL,'{ids['workshop']}','{ids['unit']}');
                INSERT INTO source_stock_facts VALUES('{source}',132,{legacy},2026,{qty},{qty},{int(qty) * 2}.0000,
                    jsonb_build_object('source_id','{source}','raw_goods_legacy',{legacy},'source_marker','unchanged-{index}'));
            """
        ordinary_goods = uuid.uuid4()
        schema += f"""
            INSERT INTO goods VALUES('{ordinary_goods}',88000,'ORDINARY_KEEP_134','普通轨道仓产品',false,'{ids['ordinary']}',NULL,'{ids['unit']}');
            INSERT INTO source_stock_facts VALUES('{uuid.uuid4()}',134,88000,2026,7,7,14.0000,'{{"normal_keep_134":true}}');
        """
        self.fixture.sql(self.database, schema, owner=True)
        identity = json.loads(self.fixture.sql(self.database, """
            SELECT jsonb_build_object('current_user',current_user,'session_user',session_user,
                'superuser',(SELECT rolsuper FROM pg_roles WHERE rolname=current_user),
                'maintenance',fn_imported_business_document_maintenance_allowed());
            """, owner=True).stdout)
        self.assertEqual(identity, {"current_user": "workshop_fixture_owner", "session_user": "workshop_fixture_owner", "superuser": False, "maintenance": True})

    def snapshot(self):
        tables = ("goods", "warehouses", "departments", "units", "workshop_bins", "workshop_material_settings", "source_stock_facts", "stock_balances", "transaction_effect")
        parts = ["'" + table + "',(SELECT COALESCE(jsonb_agg(row ORDER BY row::text),'[]'::jsonb) FROM (SELECT to_jsonb(t) row FROM " + table + " t) rows)" for table in tables]
        return self.fixture.sql(self.database, "SET TimeZone='Asia/Shanghai'; SELECT jsonb_build_object(" + ",".join(parts) + ");", owner=True).stdout.strip()

    def stage_files(self, *, missing_authority=False, extra_crosswalk=False):
        a = json.loads(self.fixture.sql(self.database, """
            SET TimeZone='Asia/Shanghai';
            SELECT jsonb_build_object('database',current_database(),'oid',(SELECT oid FROM pg_database WHERE datname=current_database()),
              'sid',(SELECT system_identifier::text FROM pg_control_system()),'department',b.workshop_department_id,'bin',b.bin_warehouse_id,
              'bin_sha',encode(sha256(convert_to(to_jsonb(b)::text,'UTF8')),'hex'),
              'warehouse_sha',encode(sha256(convert_to(to_jsonb(w)::text,'UTF8')),'hex'),
              'department_sha',encode(sha256(convert_to(to_jsonb(d)::text,'UTF8')),'hex'),
              'opened_by',b.opened_by,'opened_at',b.opened_at,'source',b.source_warehouse_id,'version',b.row_version)
            FROM workshop_bins b JOIN warehouses w ON w.id=b.bin_warehouse_id JOIN departments d ON d.id=b.workshop_department_id;
            """, owner=True).stdout)
        review = [[legacy, code, name, "五金车间", "WS_WJTZ", "五金铜铸车间", "", "REVIEWED_HISTORICAL_LOCATION", "owned-fixture.xlsx", i + 2]
                  for i, (legacy, code, name, _) in enumerate(PRODUCTS)]
        crosswalk = [[legacy, code, name, "WS_WJTZ", self.ids["extra"] if extra_crosswalk else a["bin"], "a" * 64]
                     for legacy, code, name, _ in PRODUCTS]
        authority = [["REVIEWED_OPEN_BIN_HISTORICAL_STOCK_V1", "true", a["database"], a["oid"], a["sid"], "WS_WJTZ",
                      a["department"], a["bin"], a["bin_sha"], a["warehouse_sha"], a["department_sha"], a["opened_by"],
                      a["opened_at"], a["source"], a["version"], "a" * 64, "b" * 64, "c" * 64]]
        for filename, headers, rows in (
                ("goods_workshop_stock_location_review.csv", REVIEW_HEADERS, review),
                ("workshop_stock_location_crosswalk.csv", CROSSWALK_HEADERS, crosswalk),
                ("workshop_stock_location_authority.csv", AUTHORITY_HEADERS, [] if missing_authority else authority)):
            self.fixture.copy_text(filename, csv_text(headers, rows))
        self.fixture.docker("cp", str(HELPER), self.fixture.cid + ":/tmp/reviewed_workshop_stock_location.sql")

    def execute_guard(self, name, *, expected_error=None, suffix="", validate=None):
        before = self.snapshot()
        result = self.fixture.sql(self.database, "BEGIN; UPDATE transaction_effect SET n=1;\n"
                                  "\\i /tmp/reviewed_workshop_stock_location.sql\n" + suffix
                                  + "\nROLLBACK;", owner=True, check=False)
        (OUTPUT / (name + ".stdout.log")).write_text(result.stdout, encoding="utf-8")
        (OUTPUT / (name + ".stderr.log")).write_text(result.stderr, encoding="utf-8")
        if expected_error:
            self.assertNotEqual(0, result.returncode)
            self.assertIn(expected_error, result.stderr)
        else:
            self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(before, self.snapshot(), "whole fixture facts must be restored after this transaction")
        if validate is not None:
            validate(result)
        self.results.append({"case": name, "passed": True, "expected_error": expected_error,
                             "whole_fixture_before_after_sha256": hashlib.sha256(before.encode()).hexdigest(),
                             "full_transaction_rollback_verified": True})
        return result

    def test_exact_four_identities_map_without_master_or_source_mutation(self):
        self.stage_files()
        def validate(result):
            mapped = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertEqual([p[0] for p in PRODUCTS], [row["goods_legacy_id"] for row in mapped])
            self.assertTrue(all(row["warehouse_id"] == self.ids["bin"] for row in mapped))
        self.execute_guard("exact_four", suffix="SELECT jsonb_agg(to_jsonb(s) ORDER BY goods_legacy_id) FROM reviewed_workshop_stock_location_stage s;", validate=validate)

    def test_loader_real_split_latest_and_balance_fragments_keep_quantities_and_ordinary_134(self):
        self.stage_files()
        source_path = HERE / "migrate_stock_docs.sql"
        source_bytes = source_path.read_bytes()
        source = source_bytes.decode("utf-8")
        split_start = source.index("CREATE TEMP TABLE goods_split_warehouse_stage AS")
        split = source[split_start:source.index(";", split_start) + 1]
        latest_start = source.index("CREATE TEMP TABLE legacy_latest_balance_stage ON COMMIT DROP AS")
        balance_end = source.index("-- A signed CHECK surplus", latest_start)
        balance = source[latest_start:balance_end]
        self.assertIn("reviewed.warehouse_id", split, "execute the real reviewed-priority loader, not the old fallback")
        before = json.loads(self.snapshot())
        query = """
            SELECT jsonb_build_object(
              'goods',(SELECT jsonb_agg(row ORDER BY row::text) FROM (SELECT to_jsonb(g) row FROM goods g) q),
              'source_stock_facts',(SELECT jsonb_agg(row ORDER BY row::text) FROM (SELECT to_jsonb(s) row FROM source_stock_facts s) q),
              'workshop_bins',(SELECT jsonb_agg(row ORDER BY row::text) FROM (SELECT to_jsonb(b) row FROM workshop_bins b) q),
              'workshop_material_settings',(SELECT jsonb_agg(row ORDER BY row::text) FROM (SELECT to_jsonb(s) row FROM workshop_material_settings s) q),
              'mapped',(SELECT jsonb_agg(to_jsonb(s) ORDER BY goods_legacy_id) FROM goods_split_warehouse_stage s),
              'latest',(SELECT jsonb_agg(jsonb_build_object('legacy',g.legacy_id,'warehouse',s.warehouse_id,'qty',s.fact_qty,'amount',s.total) ORDER BY g.legacy_id)
                    FROM latest_stock_balance_stage s JOIN goods g ON g.id=s.goods_id),
              'balances',(SELECT jsonb_agg(jsonb_build_object('legacy',g.legacy_id,'warehouse',s.warehouse_id,'qty',s.qty,'amount',s.amount_local,'weight',s.weight) ORDER BY g.legacy_id)
                    FROM stock_balances s JOIN goods g ON g.id=s.goods_id),
              'excluded',(SELECT count(*) FROM bootstrap_warehouse_exclusions));
        """
        stages = """
            CREATE TEMP TABLE sg_stage AS SELECT stock_legacy,goods_legacy,0::int color_legacy,year,qty,fact_qty,amount total FROM source_stock_facts;
            CREATE TEMP TABLE warehouse_target_stage(legacy_id int,action text,warehouse_id uuid);
            CREATE TEMP TABLE bootstrap_warehouse_exclusions(source_file text,source_row_id text,legacy_warehouse_id int,reason text,goods_legacy_id int,qty numeric,amount numeric);
        """ + "INSERT INTO warehouse_target_stage VALUES(132,'SPLIT',NULL),(134,'KEEP','" + self.ids["ordinary"] + "');\n"
        target_guard = ordinary_target_guard_sql(source)
        def validate(result):
            observed = json.loads(result.stdout.strip().splitlines()[-1])
            for protected in ("goods", "source_stock_facts", "workshop_bins", "workshop_material_settings"):
                self.assertEqual(before[protected], observed[protected], "during-transaction protected facts changed: " + protected)
            self.assertEqual(0, observed["excluded"])
            self.assertEqual(5, len(observed["mapped"]))
            latest = {row["legacy"]: row for row in observed["latest"]}
            balances = {row["legacy"]: row for row in observed["balances"]}
            self.assertEqual({65919, 65920, 65921, 65923, 88000}, set(latest))
            for legacy, _, _, qty in PRODUCTS:
                self.assertEqual(self.ids["bin"], latest[legacy]["warehouse"])
                self.assertEqual(int(qty), latest[legacy]["qty"])
                self.assertEqual(int(qty) * 2, latest[legacy]["amount"])
                if int(qty):
                    self.assertEqual(latest[legacy]["warehouse"], balances[legacy]["warehouse"])
                    self.assertEqual(int(qty), balances[legacy]["qty"])
                    self.assertIsNone(balances[legacy]["weight"], "条 must not invent a mass weight")
            self.assertNotIn(65923, balances, "a retained zero/zero source does not fabricate a balance row")
            self.assertEqual(self.ids["ordinary"], balances[88000]["warehouse"])
            self.assertEqual(7, balances[88000]["qty"])
            self.assertEqual(14, balances[88000]["amount"])
        self.execute_guard("real_loader_fragments", suffix=stages + target_guard + "\n" + split + "\n" + balance + "\n" + query, validate=validate)
        self.results[-1].update({"actual_stock_loader_sha256": hashlib.sha256(source_bytes).hexdigest(),
                                 "executed_split_fragment_sha256": hashlib.sha256(split.encode()).hexdigest(),
                                 "executed_latest_balance_fragment_sha256": hashlib.sha256(balance.encode()).hexdigest(),
                                 "source_zero_row_retained_without_fabricated_balance": True,
                                 "ordinary_keep_134_verified": True,
                                 "during_transaction_master_source_bin_settings_preserved": True})

    def test_ordinary_crosswalk_cannot_route_keep_134_to_an_arbitrary_line_side(self):
        self.fixture.sql(self.database, "INSERT INTO warehouses(id,code,name,parent_id,status,is_line_side,workshop_department_id) VALUES('"
                         + self.ids["extra"] + "','LS_ORDINARY_BYPASS','普通仓绕路的任意内料仓','" + self.ids["root"]
                         + "','使用',true,'" + self.ids["workshop"] + "');", owner=True)
        self.stage_files()
        source_bytes = (HERE / "migrate_stock_docs.sql").read_bytes()
        guard = ordinary_target_guard_sql(source_bytes.decode("utf-8"))
        stage = "CREATE TEMP TABLE warehouse_target_stage(legacy_id int,action text,warehouse_id uuid);\n"
        stage += "INSERT INTO warehouse_target_stage VALUES(134,'KEEP','" + self.ids["extra"] + "');\n"
        self.execute_guard("ordinary_keep_134_unauthorized_line_side", suffix=stage + guard,
                           expected_error="Ordinary legacy warehouse crosswalk cannot target any line-side bin")
        self.results[-1].update({"actual_stock_loader_sha256": hashlib.sha256(source_bytes).hexdigest(),
                                 "executed_ordinary_target_guard_sha256": hashlib.sha256(guard.encode()).hexdigest()})

    def test_missing_authority_rejects_and_rolls_back(self):
        self.stage_files(missing_authority=True)
        self.execute_guard("missing_authority", expected_error="exact four identities/review/crosswalk required")

    def test_bin_not_open_rejects_and_rolls_back(self):
        self.stage_files()
        self.fixture.sql(self.database, "DELETE FROM workshop_bins;", owner=True)
        self.execute_guard("bin_not_open", expected_error="Actual reviewed unified bin opening")

    def test_wrong_department_even_with_fresh_row_hash_rejects(self):
        self.fixture.sql(self.database, "UPDATE warehouses SET workshop_department_id='" + self.ids["other_workshop"] + "' WHERE id='" + self.ids["bin"] + "';", owner=True)
        self.stage_files()
        self.execute_guard("wrong_department", expected_error="Actual reviewed unified bin opening")

    def test_arbitrary_extra_line_side_cannot_replace_authorized_bin(self):
        self.fixture.sql(self.database, "INSERT INTO warehouses(id,code,name,parent_id,status,is_line_side,workshop_department_id) VALUES('"
                         + self.ids["extra"] + "','LS_ARBITRARY','任意额外内料仓','" + self.ids["root"]
                         + "','使用',true,'" + self.ids["workshop"] + "');", owner=True)
        self.stage_files(extra_crosswalk=True)
        self.execute_guard("arbitrary_extra_line_side", expected_error="authorization/target mismatch")

    def test_null_unit_rejects_and_rolls_back(self):
        self.fixture.sql(self.database, "UPDATE goods SET unit_id=NULL WHERE legacy_id=65921;", owner=True)
        self.stage_files()
        self.execute_guard("null_unit", expected_error="nonNULL unit required")


if __name__ == "__main__":
    unittest.main(verbosity=2)
