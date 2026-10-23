"""Real owner mapper regression in a newly created, disposable PostgreSQL 16 container.

Run with UTEN_RUN_SALES_OWNER_MIXED_DB_TESTS=1. No host ports, volumes, existing
containers, or business databases are used. Every fixture rolls back; the new
container is removed after the class, including failed tests.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import unittest
import uuid

import compose_bootstrap


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
MAPPER = HERE / "migrate_sales_owner.sql"
HELPER = HERE / "migrate_owner_custody.sql"
HEADERS = ("sales_orders", "sales_shipments", "sales_other_shipments", "sales_returns")
ADMIN = str(uuid.UUID(int=1))
ACTIVE_A = str(uuid.UUID(int=2))
ACTIVE_B = str(uuid.UUID(int=3))
RESIGNED = str(uuid.UUID(int=4))
RUN_ID = str(uuid.UUID(int=900))
REASON = "MIXED_UPSTREAM_OWNER_CUSTODY"
JSON_MARKER = "SALES_OWNER_MIXED_FIXTURE_JSON="
REAL_SHIPMENTS = {
    23186: [(18429, 129), (19351, 545)],
    23472: [(18959, 129), (19472, 545)],
    23606: [(18558, 129), (18599, 129), (19198, 545), (19285, 545),
            (19306, 545), (19727, 545), (19785, 545)],
}


def uid(namespace, legacy_id):
    return str(uuid.UUID(int=namespace * 100000000 + legacy_id))


def literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def insert(table, row):
    return "INSERT INTO " + table + "(" + ",".join(row) + ") VALUES (" + ",".join(map(literal, row.values())) + ");\n"


def strict_guard_sql():
    source = (ROOT / "server/src/main/resources/db/migration/V398__offboarding_audit_and_responsibility_race_guards.sql").read_text(encoding="utf-8")
    match = re.search(r"CREATE OR REPLACE FUNCTION fn_require_current_employee_reference_strict\(\).*?\n\$\$;", source, re.S)
    if not match:
        raise AssertionError("Cannot locate V398's original strict current-employee function")
    return match.group(0) + "\n"


class Fixture:
    def __init__(self):
        self.sql = []
        self.headers = {}
        self.expected_owners = {}
        self.order_items = {}
        self.shipment_items = {}
        self.links = []
        self.conflicts = set()

    def header(self, table, legacy_id, seller, expected_owner, *, deleted=False):
        namespace = HEADERS.index(table) + 1
        row = dict(id=uid(namespace, legacy_id), legacy_id=legacy_id,
                   seller_legacy_id=seller,
                   seller_id={545: ACTIVE_A, 546: ACTIVE_B, 777: RESIGNED}.get(seller),
                   maker_id=RESIGNED, approver_id=ACTIVE_B,
                   is_deleted=deleted, owner_employee_id=None)
        self.sql.append(insert(table, row))
        self.headers[(table, legacy_id)] = row
        self.expected_owners[(table, legacy_id)] = expected_owner
        return row

    def order(self, legacy_id, seller, *, deleted=False):
        owner = {545: ACTIVE_A, 546: ACTIVE_B, 0: None, 129: ADMIN, 777: ADMIN}[seller]
        self.header("sales_orders", legacy_id, seller, owner, deleted=deleted)
        self.order_items[legacy_id] = self.order_item(legacy_id, legacy_id * 10 + 1)

    def order_item(self, order_legacy, item_legacy, *, deleted=False):
        row = dict(id=uid(5, item_legacy), legacy_id=item_legacy,
                   order_id=self.headers[("sales_orders", order_legacy)]["id"], is_deleted=deleted)
        self.sql.append(insert("sales_order_items", row))
        return dict(row, document_legacy=order_legacy)

    def link(self, target_table, target_legacy, target_item, upstream_kind,
             source_table, source_legacy, source_item):
        source = self.headers[(source_table, source_legacy)]
        self.links.append(dict(
            target_table=target_table, target_legacy=target_legacy,
            target_item_id=target_item["id"], target_item_legacy_id=target_item["legacy_id"],
            upstream_kind=upstream_kind, upstream_document_table=source_table,
            upstream_document_id=source["id"], upstream_document_legacy_id=source_legacy,
            upstream_item_id=source_item["id"], upstream_item_legacy_id=source_item["legacy_id"],
            source_seller_legacy_id=source["seller_legacy_id"],
            resolved_owner_employee_id=self.expected_owners[(source_table, source_legacy)],
            eligible=not (target_item["is_deleted"] or source_item["is_deleted"] or source["is_deleted"])))

    def shipment(self, legacy_id, order_legacy_ids, owner, *, seller=545, mixed=False):
        self.header("sales_shipments", legacy_id, seller, owner)
        self.shipment_items[legacy_id] = []
        for order in order_legacy_ids:
            self.shipment_item(legacy_id, self.order_items[order])
        if mixed:
            self.conflicts.add(("sales_shipments", legacy_id))

    def shipment_item(self, shipment_legacy, source_item, *, deleted=False):
        index = len(self.shipment_items[shipment_legacy]) + 1
        item_legacy = shipment_legacy * 100 + index
        row = dict(id=uid(6, item_legacy), legacy_id=item_legacy,
                   shipment_id=self.headers[("sales_shipments", shipment_legacy)]["id"],
                   order_item_id=source_item["id"] if source_item else None, is_deleted=deleted)
        self.sql.append(insert("sales_shipment_items", row))
        self.shipment_items[shipment_legacy].append(dict(row, document_legacy=shipment_legacy))
        if source_item:
            self.link("sales_shipments", shipment_legacy, row, "ORDER_ITEM", "sales_orders",
                      source_item["document_legacy"], source_item)
        return self.shipment_items[shipment_legacy][-1]

    def returned(self, legacy_id, owner, *, seller=0, mixed=False):
        self.header("sales_returns", legacy_id, seller, owner)
        if mixed:
            self.conflicts.add(("sales_returns", legacy_id))

    def return_item(self, return_legacy, index, *, shipment_item=None, order=None, deleted=False):
        item_legacy = return_legacy * 100 + index
        order_item = self.order_items.get(order)
        row = dict(id=uid(7, item_legacy), legacy_id=item_legacy,
                   return_id=self.headers[("sales_returns", return_legacy)]["id"],
                   out_item_id=shipment_item["id"] if shipment_item else None,
                   order_item_id=order_item["id"] if order_item else None, is_deleted=deleted)
        self.sql.append(insert("sales_return_items", row))
        if shipment_item:
            self.link("sales_returns", return_legacy, row, "SHIPMENT_ITEM", "sales_shipments",
                      shipment_item["document_legacy"], shipment_item)
        if order_item:
            self.link("sales_returns", return_legacy, row, "ORDER_ITEM", "sales_orders", order, order_item)

    def expected_references(self, key):
        return [{field: value for field, value in link.items()
                 if field not in ("target_table", "target_legacy", "eligible")}
                for link in self.links
                if (link["target_table"], link["target_legacy"]) == key and link["eligible"]]


def source_fixture():
    fixture = Fixture()
    for sources in REAL_SHIPMENTS.values():
        for order, seller in sources:
            fixture.order(order, seller)
    for shipment, sources in REAL_SHIPMENTS.items():
        fixture.shipment(shipment, [order for order, _ in sources], ADMIN, mixed=True)
    for order, seller in [(50001, 545), (50002, 546), (50003, 0), (50004, 777), (50005, 545)]:
        fixture.order(order, seller)
    fixture.order(50006, 546, deleted=True)
    # A third, public source remains a real audit reference with a null owner.
    fixture.shipment(51001, [50001, 50002, 50003], ADMIN, seller=546, mixed=True)
    fixture.shipment(51002, [50001], ACTIVE_A)
    fixture.shipment(51003, [50003], None, seller=0)
    fixture.shipment(51004, [], None, seller=0)
    fixture.shipment_item(51004, None)
    fixture.shipment(51005, [50005], ACTIVE_A)
    fixture.shipment_item(51005, fixture.order_items[50002], deleted=True)
    deleted_order_item = fixture.order_item(50002, 599999, deleted=True)
    fixture.shipment_item(51005, deleted_order_item)
    fixture.shipment_item(51005, fixture.order_items[50006])
    fixture.shipment(51006, [50001, 50004], ADMIN, mixed=True)
    fixture.header("sales_other_shipments", 52001, 777, ADMIN)
    fixture.header("sales_other_shipments", 52002, 0, None)
    fixture.returned(53001, ADMIN, seller=545, mixed=True)
    fixture.return_item(53001, 1, shipment_item=fixture.shipment_items[51002][0], order=50002)
    fixture.return_item(53001, 2, order=50003)
    fixture.returned(53002, ACTIVE_A)
    fixture.return_item(53002, 1, shipment_item=fixture.shipment_items[51002][0])
    fixture.returned(53003, None)
    fixture.return_item(53003, 1, shipment_item=fixture.shipment_items[51003][0], order=50003)
    fixture.returned(53004, None)
    fixture.return_item(53004, 1)
    fixture.returned(53005, ACTIVE_A)
    fixture.return_item(53005, 1, shipment_item=fixture.shipment_items[51002][0], order=50001)
    return fixture


def schema_sql():
    sql = """BEGIN;
CREATE TABLE employees(id uuid PRIMARY KEY,legacy_id int UNIQUE,code text,full_name text,status text,is_deleted boolean NOT NULL DEFAULT false);
CREATE TABLE users(id uuid PRIMARY KEY,employee_id uuid REFERENCES employees(id),login_account text,is_super_admin boolean,status text,is_deleted boolean);
CREATE TABLE legacy_migration_runs(run_id uuid PRIMARY KEY,status text,started_at timestamptz DEFAULT now(),reconciliation_summary jsonb NOT NULL);
"""
    for table in HEADERS:
        sql += "CREATE TABLE " + table + "(id uuid PRIMARY KEY,legacy_id int UNIQUE,seller_legacy_id int,seller_id uuid,maker_id uuid,approver_id uuid,is_deleted boolean NOT NULL DEFAULT false,owner_employee_id uuid REFERENCES employees(id));\n"
    sql += """CREATE TABLE sales_order_items(id uuid PRIMARY KEY,legacy_id int UNIQUE,order_id uuid REFERENCES sales_orders(id),is_deleted boolean NOT NULL DEFAULT false);
CREATE TABLE sales_shipment_items(id uuid PRIMARY KEY,legacy_id int UNIQUE,shipment_id uuid REFERENCES sales_shipments(id),order_item_id uuid REFERENCES sales_order_items(id),is_deleted boolean NOT NULL DEFAULT false);
CREATE TABLE sales_return_items(id uuid PRIMARY KEY,legacy_id int UNIQUE,return_id uuid REFERENCES sales_returns(id),out_item_id uuid REFERENCES sales_shipment_items(id),order_item_id uuid REFERENCES sales_order_items(id),is_deleted boolean NOT NULL DEFAULT false);
CREATE MATERIALIZED VIEW sales_monthly_mv AS SELECT owner_employee_id,count(*) AS rows FROM sales_orders GROUP BY owner_employee_id;
"""
    sql += strict_guard_sql()
    for table in HEADERS:
        sql += "CREATE TRIGGER fixture_strict_current_owner BEFORE INSERT OR UPDATE OF owner_employee_id,is_deleted ON " + table + " FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference_strict('owner_employee_id');\n"
        sql += "ALTER TABLE " + table + " ENABLE ALWAYS TRIGGER fixture_strict_current_owner;\n"
    for employee, legacy, code, status in [(ADMIN, None, "ADMIN", "active"), (ACTIVE_A, 545, "UT0002", "active"),
                                          (ACTIVE_B, 546, "UT0003", "onLeave"), (RESIGNED, 777, "UT0192", "resigned")]:
        sql += insert("employees", dict(id=employee, legacy_id=legacy, code=code, full_name="synthetic fixture", status=status, is_deleted=False))
    sql += insert("users", dict(id=uid(8, 1), employee_id=ADMIN, login_account="17665410007", is_super_admin=True, status="active", is_deleted=False))
    sql += "INSERT INTO legacy_migration_runs VALUES (" + literal(RUN_ID) + ",'RUNNING',now(),jsonb_build_object('targetDatabase',current_database(),'unrelatedEvidence',jsonb_build_object('preserved',true)));\n"
    sql += "SELECT set_config('uten.bootstrap_run_id'," + literal(RUN_ID) + ",true);\n"
    return sql


def rejected_resigned_owner_sql():
    return """DO $$ DECLARE target text; key uuid; rejected boolean; BEGIN
 FOREACH target IN ARRAY ARRAY['sales_orders','sales_shipments','sales_other_shipments','sales_returns'] LOOP
  EXECUTE format('SELECT id FROM %I ORDER BY legacy_id LIMIT 1',target) INTO key;
  rejected:=false;
  BEGIN
   EXECUTE format('UPDATE %I SET owner_employee_id=$1 WHERE id=$2',target) USING '00000000-0000-0000-0000-000000000004'::uuid,key;
  EXCEPTION WHEN check_violation THEN rejected:=true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'V398 strict owner guard did not reject resigned employee for %',target; END IF;
 END LOOP;
END $$;
"""


@unittest.skipUnless(os.environ.get("UTEN_RUN_SALES_OWNER_MIXED_DB_TESTS") == "1",
                     "set UTEN_RUN_SALES_OWNER_MIXED_DB_TESTS=1 for a new disposable PostgreSQL 16 container")
class SalesOwnerMixedCustodyPostgresTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = "uten-sales-owner-mixed-test-" + uuid.uuid4().hex[:12]
        cls.database = "sales_owner_mixed_fixture"
        cls.mapper_bytes = MAPPER.read_bytes()
        cls.helper_bytes = HELPER.read_bytes()
        cls.addClassCleanup(cls.remove_container)
        started = subprocess.run(["docker", "run", "--rm", "--name", cls.container,
                                  "-e", "POSTGRES_PASSWORD=disposable-fixture-only",
                                  "-e", "POSTGRES_DB=" + cls.database, "-d", "postgres:16-alpine"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        if started.returncode:
            raise AssertionError(started.stderr.decode("utf-8", errors="replace"))
        for _ in range(150):
            ready = subprocess.run(["docker", "exec", cls.container, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", cls.database],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            if ready.returncode == 0:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("Disposable PostgreSQL container did not become ready")
        version = cls.psql("SHOW server_version;")
        if version.returncode or not version.stdout.decode().strip().startswith("16."):
            raise AssertionError("Fixture must run PostgreSQL 16")

    @classmethod
    def remove_container(cls):
        if not cls.container.startswith("uten-sales-owner-mixed-test-") or cls.container == "uten-imp-postgres":
            raise AssertionError("Refusing to remove a container outside this test")
        subprocess.run(["docker", "rm", "--force", cls.container], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    @classmethod
    def psql(cls, sql):
        if not cls.container.startswith("uten-sales-owner-mixed-test-") or cls.database != "sales_owner_mixed_fixture":
            raise AssertionError("Refusing to connect outside the disposable fixture")
        return subprocess.run(["docker", "exec", "-i", cls.container, "psql", "-X", "-q", "-A", "-t",
                               "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", cls.database],
                              input=sql.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)

    def module(self):
        self.assertEqual(self.mapper_bytes, MAPPER.read_bytes(), "Frozen mapper changed during regression")
        self.assertEqual(self.helper_bytes, HELPER.read_bytes(), "Frozen shared helper changed during regression")
        return compose_bootstrap.compose(self.mapper_bytes, MAPPER.name).decode("utf-8")

    def run_fixture(self, *, repeat=False, admin_mutation=None):
        fixture = source_fixture()
        sql = schema_sql() + "".join(fixture.sql) + rejected_resigned_owner_sql()
        if admin_mutation:
            sql += admin_mutation + "\n"
        sql += self.module()
        sql += "CREATE TABLE fixture_first_summary AS SELECT reconciliation_summary AS summary FROM legacy_migration_runs;\n"
        if repeat:
            sql += self.module()
        sql += rejected_resigned_owner_sql()
        header_union = " UNION ALL ".join("SELECT " + literal(table) + " AS target_table,to_jsonb(header_row) AS document FROM " + table + " header_row" for table in HEADERS)
        sql += "SELECT " + literal(JSON_MARKER) + "||jsonb_build_object('summary',(SELECT reconciliation_summary FROM legacy_migration_runs),'firstSummary',(SELECT summary FROM fixture_first_summary),'headers',(SELECT jsonb_agg(jsonb_build_object('target_table',h.target_table,'row',h.document) ORDER BY h.target_table,h.document->>'legacy_id') FROM (" + header_union + ") h),'guards',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'enabled',t.tgenabled)) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid WHERE t.tgname='fixture_strict_current_owner'),'sessionRole',current_setting('session_replication_role'),'resignedStatus',(SELECT status FROM employees WHERE id=" + literal(RESIGNED) + "))::text;\nROLLBACK;\n"
        result = self.psql(sql)
        if admin_mutation:
            self.assertNotEqual(0, result.returncode, "Wrong protected ADMIN was accepted")
            self.assertIn("requires the unique preserved active super-administrator", result.stderr.decode("utf-8", errors="replace"))
            return None
        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", errors="replace"))
        lines = [line[len(JSON_MARKER):] for line in result.stdout.decode("utf-8").splitlines() if line.startswith(JSON_MARKER)]
        self.assertEqual(1, len(lines), result.stdout.decode("utf-8", errors="replace"))
        payload = json.loads(lines[0])
        self.assertEqual("origin", payload["sessionRole"])
        self.assertEqual("resigned", payload["resignedStatus"])
        self.assertEqual(set(HEADERS), {guard["table"] for guard in payload["guards"]})
        self.assertTrue(all(guard["enabled"] == "A" for guard in payload["guards"]))
        self.assertEqual({"preserved": True}, payload["summary"]["unrelatedEvidence"])
        return fixture, payload

    def assert_conflicts(self, fixture, summary):
        conflicts = summary["salesOwnerConflicts"]
        self.assertEqual("mixed-upstream-owner-custody-v1", conflicts["mappingVersion"])
        self.assertEqual(len(fixture.conflicts), conflicts["objectCount"])
        objects = {(entry["target_table"], entry["target_legacy_id"]): entry for entry in conflicts["objects"]}
        self.assertEqual(fixture.conflicts, set(objects))
        for key, entry in objects.items():
            self.assertEqual(fixture.headers[key]["id"], entry["target_id"])
            self.assertEqual(REASON, entry["reason"])
            self.assertEqual(ADMIN, entry["assigned_employee_id"])
            expected_refs = fixture.expected_references(key)
            self.assertEqual(sorted({ref["resolved_owner_employee_id"] for ref in expected_refs if ref["resolved_owner_employee_id"]}), entry["resolved_owner_ids"])
            fields = set(expected_refs[0])
            observed_refs = [{field: ref[field] for field in fields} for ref in entry["upstream_references"]]
            self.assertEqual(sorted(map(lambda value: json.dumps(value, sort_keys=True), expected_refs)),
                             sorted(map(lambda value: json.dumps(value, sort_keys=True), observed_refs)), key)
        custody = summary["currentOwnerCustody"][MAPPER.name]
        entries = {(entry["target_table"], entry["target_id"]): entry for entry in custody["entries"]}
        for key in fixture.conflicts:
            entry = entries[(key[0], fixture.headers[key]["id"])]
            self.assertEqual(REASON, entry["reason"])
            self.assertEqual(ADMIN, entry["assigned_employee_id"])
        self.assertEqual(hashlib.sha256(self.helper_bytes).hexdigest(), custody["helperSha256"])

    def test_real_three_merged_shipments_have_complete_custody_evidence(self):
        fixture, payload = self.run_fixture()
        self.assert_conflicts(fixture, payload["summary"])
        for shipment, sources in REAL_SHIPMENTS.items():
            key = ("sales_shipments", shipment)
            self.assertEqual(len(sources), len(fixture.expected_references(key)))
        self.assertEqual(11, sum(len(sources) for sources in REAL_SHIPMENTS.values()))

    def test_all_historical_actor_snapshots_remain_unchanged(self):
        fixture, payload = self.run_fixture()
        for observed in payload["headers"]:
            row = observed["row"]
            key = (observed["target_table"], row["legacy_id"])
            self.assertEqual(fixture.expected_owners[key], row["owner_employee_id"], key)
            expected = dict(fixture.headers[key])
            expected.pop("owner_employee_id")
            actual = dict(row)
            actual.pop("owner_employee_id")
            self.assertEqual(expected, actual, "Only owner may change: " + repr(key))

    def test_two_active_owners_and_mixed_return_do_not_choose_one_owner(self):
        fixture, payload = self.run_fixture()
        self.assert_conflicts(fixture, payload["summary"])
        objects = {(item["target_table"], item["target_legacy_id"]): item for item in payload["summary"]["salesOwnerConflicts"]["objects"]}
        self.assertEqual(sorted([ACTIVE_A, ACTIVE_B]), objects[("sales_shipments", 51001)]["resolved_owner_ids"])
        self.assertEqual(sorted([ADMIN, ACTIVE_A]), objects[("sales_shipments", 51006)]["resolved_owner_ids"])
        returned = objects[("sales_returns", 53001)]
        self.assertEqual({"ORDER_ITEM", "SHIPMENT_ITEM"}, {ref["upstream_kind"] for ref in returned["upstream_references"]})
        self.assertTrue(any(ref["resolved_owner_employee_id"] is None for ref in returned["upstream_references"]))

    def test_single_owner_public_sources_and_deleted_links_are_not_guessed(self):
        fixture, payload = self.run_fixture()
        rows = {(item["target_table"], item["row"]["legacy_id"]): item["row"] for item in payload["headers"]}
        for legacy in (51002, 51005):
            self.assertEqual(ACTIVE_A, rows[("sales_shipments", legacy)]["owner_employee_id"])
        for key in [("sales_shipments", 51003), ("sales_shipments", 51004), ("sales_other_shipments", 52002),
                    ("sales_returns", 53003), ("sales_returns", 53004)]:
            self.assertIsNone(rows[key]["owner_employee_id"], key)
        for legacy in (53002, 53005):
            self.assertEqual(ACTIVE_A, rows[("sales_returns", legacy)]["owner_employee_id"])
        self.assertNotIn(("sales_shipments", 51005), fixture.conflicts)

    def test_repeated_mapping_retains_evidence_and_strict_guards(self):
        fixture, payload = self.run_fixture(repeat=True)
        self.assert_conflicts(fixture, payload["summary"])
        self.assertEqual(payload["firstSummary"]["salesOwnerConflicts"], payload["summary"]["salesOwnerConflicts"])
        self.assertEqual(payload["firstSummary"]["currentOwnerCustody"][MAPPER.name],
                         payload["summary"]["currentOwnerCustody"][MAPPER.name])
        leftover = self.psql("SELECT count(*) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname IN ('sales_orders','legacy_migration_runs');")
        self.assertEqual(0, leftover.returncode)
        self.assertEqual("0", leftover.stdout.decode().strip(), "Every fixture must roll back")

    def test_invalid_protected_admin_is_rejected(self):
        for mutation in ["UPDATE users SET is_super_admin=false;", "UPDATE users SET login_account='not-the-preserved-login';",
                         "UPDATE employees SET code='NOT_ADMIN' WHERE id=" + literal(ADMIN) + ";",
                         "UPDATE employees SET status='resigned' WHERE id=" + literal(ADMIN) + ";"]:
            with self.subTest(mutation=mutation):
                self.run_fixture(admin_mutation=mutation)


if __name__ == "__main__":
    unittest.main()
