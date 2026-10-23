import copy
import json
from pathlib import Path
import re
import subprocess
import time
import unittest
import uuid

import compose_bootstrap
import prepare_injection_material_bom as subject


def fixture(material_text="PC E-15"):
    goods = [
        {"legacy_id": "52620", "code": "1M0004", "name": "1M三开中按钮", "material": material_text,
         "unit_legacy_id": "92", "z_weight": "0", "m_weight": "0"},
        {"legacy_id": "14533", "code": "280501002", "name": "PC面板料E-15", "material": "PC", "unit_legacy_id": "108"},
        {"legacy_id": "18657", "code": "280501028", "name": "PC面料（水口料E-15）", "unit_legacy_id": "108"},
        {"legacy_id": "24922", "code": "BF003", "name": "PC E-15不良品", "unit_legacy_id": "108"}]
    attributes = [{"legacy_id": "52620", "source_type": "自制", "workshop_name": "注塑车间"}]
    excel = {"1m0004": {"path": "products.xls", "sha256": "a" * 64, "row": 6,
                         "values": {"产品编号": "1M0004", "产品角色": "自制件", "生产车间": "注塑车间", "材质": material_text}}}
    raw = {"52620": {**goods[0], "_source_row": 20}}
    bindings = {"raw_goods": {"path": "raw/goods.csv", "sha256": "b" * 64},
                "final_goods": {"path": "final/goods.csv", "sha256": "c" * 64},
                "bom": {"path": "clean/goods_bom.csv", "sha256": "d" * 64}}
    for row in goods:
        row.update(parent_legacy="2120", status="使用")
    goods[1]["model"] = "E-15"
    return goods, attributes, excel, raw, bindings


def inspect_fixture(goods, attributes, bom, excel, raw, bindings):
    catalog, aliases = subject.material_catalog(goods, [{"legacy_id": "2120", "parent_legacy": "0", "name": "塑胶原料"}],
                                                 [{"legacy_id": "108", "name": "kg"}], attributes)
    return subject.inspect(goods, attributes, bom, excel, raw, bindings, catalog, aliases)


def default_relations():
    goods, attributes, excel, raw, bindings = fixture()
    return inspect_fixture(goods, attributes, [], excel, raw, bindings)[1]


class InjectionMaterialPreparationTest(unittest.TestCase):
    def inspect(self, *, material_text="PC E-15", bom=None, alter=None):
        goods, attributes, excel, raw, bindings = fixture(material_text)
        if alter:
            alter(goods, attributes, excel)
        return inspect_fixture(goods, attributes, [] if bom is None else bom, excel, raw, bindings)

    def test_example_has_neutral_identity_without_a_quantity_or_fake_edge(self):
        audit, relationships = self.inspect()
        self.assertEqual(len(relationships), 1)
        self.assertEqual(relationships[0]["material_legacy_id"], "14533")
        self.assertNotIn("qty", relationships[0])
        proof = json.loads(relationships[0]["provenance"])
        self.assertTrue(proof["quantity_unknown"])
        self.assertFalse(proof["active_bom_edge_added"])
        self.assertEqual(proof["raw_goods"]["row"], 20)
        self.assertEqual(proof["excel"]["sha256"], "a" * 64)

    def test_case_and_whitespace_are_strict_synonyms(self):
        for value in ("PC  E-15", "pc e-15", "PC面板料E-15"):
            self.assertEqual(len(self.inspect(material_text=value)[1]), 1)

    def test_different_formula_regrind_or_defective_text_is_not_mapped(self):
        for value in ("PC E-15(960)", "PC E-15A", "PC水口料E-15", "PC E-15不良品", "PC E-15+色粉"):
            self.assertEqual(self.inspect(material_text=value)[1], [])

    def test_existing_component_structure_stays_intact_and_requires_layer_review(self):
        edge = {"legacy_id": "439031", "goods_legacy_id": "52620", "component_legacy_id": "18657", "qty": "1"}
        before = copy.deepcopy(edge)
        audit, relationships = self.inspect(bom=[edge])
        self.assertEqual(edge, before)
        self.assertEqual(audit[0]["placement_state"], "EXISTING_COMPONENT_LAYERS_REVIEW_NO_DOUBLE_INPUT")
        self.assertTrue(json.loads(relationships[0]["provenance"])["needs_child_layer_review"])
        self.assertEqual(relationships[0]["material_legacy_id"], "14533")

    def test_existing_direct_or_descendant_bom_is_not_duplicated(self):
        direct = [{"goods_legacy_id": "52620", "component_legacy_id": "14533", "qty": "0.004"}]
        self.assertEqual(self.inspect(bom=direct)[1], [])
        indirect = [{"goods_legacy_id": "52620", "component_legacy_id": "18657", "qty": "1"},
                    {"goods_legacy_id": "18657", "component_legacy_id": "14533", "qty": "0.004"}]
        self.assertEqual(self.inspect(bom=indirect)[1], [])

    def test_cycle_is_reported_without_creating_a_relation(self):
        audit, relationships = self.inspect(bom=[{"goods_legacy_id": "14533", "component_legacy_id": "52620", "qty": "1"}])
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "SELF_OR_CYCLE_REVIEW")

    def test_excel_scope_must_confirm_injection_workshop_and_in_house_role(self):
        with self.assertRaisesRegex(ValueError, "exact Excel product identity"):
            self.inspect(alter=lambda goods, attributes, excel: excel["1m0004"]["values"].update(产品角色="外购件"))

    def test_neutral_sql_is_accepted_by_composition_guard(self):
        self.assertIn(b"goods_material_identity_evidence",
                      compose_bootstrap.compose(subject.render_loader(default_relations()).encode("utf-8"), "goods_material_identity.sql"))
        self.assertIsNone(re.search(r"(?m)^\s*COMMIT\s*;", subject.LOAD_SQL))

    def test_other_grade_maps_unique_proven_identity_and_excludes_regrind(self):
        goods, attributes, excel, raw, bindings = fixture("PC G-7")
        goods.extend([{"legacy_id": "99", "code": "R99", "name": "PC支架料G-7", "model": "G-7", "material": "PC", "unit_legacy_id": "108", "parent_legacy": "2120", "status": "使用"},
                      {"legacy_id": "100", "code": "R100", "name": "PC水口料G-7", "model": "G-7", "material": "PC", "unit_legacy_id": "108", "parent_legacy": "2120", "status": "使用"}])
        _, relationships = inspect_fixture(goods, attributes, [], excel, raw, bindings)
        self.assertEqual([row["material_legacy_id"] for row in relationships], ["99"])

    def test_ambiguous_identity_is_not_resolved_merely_by_enabled_status(self):
        goods, attributes, excel, raw, bindings = fixture("PC F812-40A")
        for identity, status in (("99", "使用"), ("100", "禁用")):
            goods.append({"legacy_id": identity, "code": "R"+identity, "name": "PC深灰"+identity, "model": "F812-40A", "material": "PC", "unit_legacy_id": "108", "parent_legacy": "2120", "status": status})
        audit, relationships = inspect_fixture(goods, attributes, [], excel, raw, bindings)
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "AMBIGUOUS_RAW_IDENTITIES")

    def test_existing_bom_resolves_ambiguous_identity_without_a_new_unknown_quantity(self):
        goods, attributes, excel, raw, bindings = fixture("PC F812-40A")
        for identity in ("99", "100"):
            goods.append({"legacy_id": identity, "code": "R"+identity, "name": "PC深灰"+identity, "model": "F812-40A", "material": "PC", "unit_legacy_id": "108", "parent_legacy": "2120", "status": "使用"})
        edge = {"legacy_id": "9", "goods_legacy_id": "52620", "component_legacy_id": "99", "qty": "0.025", "color_legacy_id": "345"}
        audit, relationships = inspect_fixture(goods, attributes, [edge], excel, raw, bindings)
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "ALREADY_DEFINED_ACTIVE_BOM")
        links = subject.bom_link_audit(audit, [edge], goods)
        facts = json.loads(links[0]["preserved_path_edge_facts"])
        self.assertEqual((facts[0]["qty"], facts[0]["color_legacy_id"], facts[0]["component_unit_legacy_id"]), ("0.025", "345", "108"))

    def test_disabled_raw_material_is_reported_without_neutral_or_bom_record(self):
        def disable(goods, attributes, excel):
            goods[1]["status"] = "禁用"
        audit, relationships = self.inspect(alter=disable)
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "DISABLED_RAW_MATERIAL")

    def test_blank_material_with_real_bom_is_not_a_missing_leaf(self):
        edge = {"goods_legacy_id": "52620", "component_legacy_id": "14533", "qty": "0.025"}
        defined, _ = self.inspect(material_text="", bom=[edge])
        leaf, _ = self.inspect(material_text="")
        self.assertEqual(defined[0]["state"], "ALREADY_DEFINED_ACTIVE_BOM")
        self.assertEqual(leaf[0]["state"], "BLANK_MANUFACTURING_LEAF_PENDING")

    def test_960_grade_is_not_collapsed_to_unqualified_base_grade(self):
        goods, attributes, excel, raw, bindings = fixture("PC F-58(960)")
        for identity, model in (("99", "F-58"), ("100", "F-58(960)")):
            goods.append({"legacy_id": identity, "code": "R"+identity, "name": model+"PC料", "model": model, "material": "PC", "unit_legacy_id": "108", "parent_legacy": "2120", "status": "使用"})
        _, relationships = inspect_fixture(goods, attributes, [], excel, raw, bindings)
        self.assertEqual([row["material_legacy_id"] for row in relationships], ["100"])

    def test_generic_polymer_is_not_promoted_to_a_special_formula(self):
        goods, attributes, excel, raw, bindings = fixture("PA66")
        goods.append({"legacy_id": "99", "code": "R99", "name": "PA66101-ML子弹头专用料（加纤）", "model": "PA66101-ML", "material": "PA66", "unit_legacy_id": "108", "parent_legacy": "2120", "status": "使用"})
        audit, relationships = inspect_fixture(goods, attributes, [], excel, raw, bindings)
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "GENERIC_MATERIAL_NEEDS_GRADE_OR_SPECIFICATION")

    def test_raw_classification_and_proven_mass_unit_are_required(self):
        goods, attributes, excel, raw, bindings = fixture()
        for categories, units in (([{"legacy_id": "2120", "parent_legacy": "0", "name": "塑胶件"}], [{"legacy_id": "108", "name": "kg"}]),
                                  ([{"legacy_id": "2120", "parent_legacy": "0", "name": "塑胶原料"}], [{"legacy_id": "108", "name": "个"}])):
            catalog, aliases = subject.material_catalog(goods, categories, units)
            audit, relationships = subject.inspect(goods, attributes, [], excel, raw, bindings, catalog, aliases)
            self.assertEqual(relationships, [])
            self.assertEqual(audit[0]["state"], "RAW_CLASSIFICATION_OR_MASS_UNIT_UNPROVEN")

    def test_blank_old_bom_with_only_disabled_components_is_a_separate_review_state(self):
        goods, attributes, excel, raw, bindings = fixture("")
        goods[1]["status"] = "禁用"
        edge = {"goods_legacy_id": "52620", "component_legacy_id": "14533", "qty": "1"}
        audit, relationships = inspect_fixture(goods, attributes, [edge], excel, raw, bindings)
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "BLANK_MATERIAL_WITH_ONLY_EXCLUDED_BOM_ROWS")

    def test_blank_material_with_indirect_positive_bom_is_covered_with_original_edge_facts(self):
        goods, attributes, excel, raw, bindings = fixture("")
        goods.append({"legacy_id": "99", "code": "PART99", "name": "中间塑件", "material": "", "unit_legacy_id": "92", "parent_legacy": "2120", "status": "使用"})
        edges = [{"legacy_id": "7", "goods_legacy_id": "52620", "component_legacy_id": "99", "qty": "2", "color_legacy_id": "345"},
                 {"legacy_id": "8", "goods_legacy_id": "99", "component_legacy_id": "14533", "qty": "0.003", "color_legacy_id": "347"}]
        audit, relationships = inspect_fixture(goods, attributes, edges, excel, raw, bindings)
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "ALREADY_COVERED_INDIRECT_BOM")
        links = subject.bom_link_audit(audit, edges, goods)
        facts = json.loads(next(row["preserved_path_edge_facts"] for row in links if row["product_legacy_id"] == "52620"))
        self.assertEqual([(row["qty"], row["color_legacy_id"], row["component_unit_legacy_id"]) for row in facts],
                         [("2", "345", "92"), ("0.003", "347", "108")])

    def test_real_bom_with_conflicting_blend_text_preserves_structure_without_claiming_text_resolved(self):
        goods, attributes, excel, raw, bindings = fixture("PA66+纤维")
        goods.append({"legacy_id": "14546", "code": "280501015", "name": "PA66黑色尼龙料", "model": "", "material": "PA66", "unit_legacy_id": "108", "parent_legacy": "2120", "status": "使用"})
        edge = {"legacy_id": "471048", "goods_legacy_id": "52620", "component_legacy_id": "14546", "qty": "0.001", "color_legacy_id": "347"}
        audit, relationships = inspect_fixture(goods, attributes, [edge], excel, raw, bindings)
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "ALREADY_DEFINED_BOM_WITH_MATERIAL_TEXT_REVIEW")
        self.assertEqual(audit[0]["material_text_resolution_status"], "MIXTURE_FORMULA_REQUIRES_REVIEW")
        summary = subject.scope_summary([audit[0]], relationships)
        self.assertEqual(summary["resolved_raw_identity_products"], 1)
        self.assertEqual(summary["resolved_nonempty_material_products"], 0)

    def test_explicit_mixture_without_a_matching_single_raw_master_is_review_only(self):
        audit, relationships = self.inspect(material_text="PC E-15+色粉")
        self.assertEqual(relationships, [])
        self.assertEqual(audit[0]["state"], "MIXTURE_FORMULA_REQUIRES_REVIEW")

    def test_33603_lifecycle_note_keeps_enabled_injection_product_and_e15_identity(self):
        def historical(goods, attributes, excel):
            goods[0].update(legacy_id="33603", code="V50094", name="V5三极多功能带USB插面（不再生产）")
            attributes[0]["legacy_id"]="33603"
            excel["v50094"]=excel.pop("1m0004")
            excel["v50094"]["values"]["产品编号"]="V50094"
        audit, relations=self.inspect(alter=historical)
        self.assertEqual([(row["product_legacy_id"],row["material_legacy_id"]) for row in relations],[("33603","14533")])
        self.assertEqual(audit[0]["state"],"RESOLVED_UNIQUE_LITERAL_IDENTITY")

    def test_33605_disabled_lifecycle_product_without_excel_material_creates_no_identity(self):
        goods, attributes, excel, raw, bindings=fixture("")
        goods[0].update(legacy_id="33605",code="V50096",name="V5USB安全盖（不再生产）",status="禁用")
        audit, relations=inspect_fixture(goods,[],[],{},raw,bindings)
        self.assertEqual(relations,[])
        self.assertEqual(audit[0]["state"],"EMPTY_MATERIAL")

    def test_lifecycle_reproduction_and_scrap_container_names_are_not_contents(self):
        for name in ("正常塑件（不再生产）","再生产用开关面板","废料收集桶","不良品周转箱","水口料筐"):
            with self.subTest(name=name):
                audit, relations=self.inspect(alter=lambda goods,attributes,excel:goods[0].update(name=name))
                self.assertEqual(len(relations),1)
                self.assertNotEqual(audit[0]["state"],"OUTPUT_PRODUCT_NOT_NORMAL_INPUT")

    def test_normal_part_material_mixture_is_not_an_output_or_an_invented_input_split(self):
        audit, relations=self.inspect(material_text="PC+水口")
        self.assertEqual(relations,[])
        self.assertEqual(audit[0]["state"],"MIXTURE_FORMULA_REQUIRES_REVIEW")

    def test_actual_output_full_identity_still_excludes_normal_input_mapping(self):
        for name in ("PC水口料E-15","PC E-15不良品","PC废料","塑胶边角料"):
            with self.subTest(name=name):
                audit, relations=self.inspect(alter=lambda goods,attributes,excel:goods[0].update(name=name))
                self.assertEqual(relations,[])
                self.assertEqual(audit[0]["state"],"OUTPUT_PRODUCT_NOT_NORMAL_INPUT")

    def test_recycled_purchased_raw_master_is_not_automatically_waste_and_can_match_exactly(self):
        goods,attributes,excel,raw,bindings=fixture("POM黑色（再生料）")
        goods.append({"legacy_id":"14550","code":"POM-RECYCLED","name":"POM黑色（再生料）","material":"POM",
                      "model":"","unit_legacy_id":"108","parent_legacy":"2120","status":"使用"})
        attributes.append({"legacy_id":"14550","source_type":"采购","workshop_name":""})
        _,relations=inspect_fixture(goods,attributes,[],excel,raw,bindings)
        self.assertEqual([row["material_legacy_id"] for row in relations],["14550"])
        goods[-1]["status"]="禁用"
        audit,relations=inspect_fixture(goods,attributes,[],excel,raw,bindings)
        self.assertEqual(relations,[])
        self.assertEqual(audit[0]["state"],"DISABLED_RAW_MATERIAL")

    def test_purchased_offcut_category_is_purpose_review_not_proven_factory_output_or_normal_input(self):
        record={"legacy_id":"21437","name":"磷铜边料"}
        role,evidence=subject.material_role(record,("原材料","五金原料","五金边料"),True,{"source_type":"采购"})
        self.assertEqual(role,"SECONDARY_MATERIAL_PURPOSE_REVIEW")
        self.assertEqual(evidence["rule"],"PURCHASED_SECONDARY_MATERIAL_PURPOSE_REQUIRES_REVIEW")

    def test_stopped_normal_component_keeps_real_bom_layer_instead_of_fake_quantity(self):
        edge={"legacy_id":"1","goods_legacy_id":"52620","component_legacy_id":"14533","qty":"0.025"}
        audit,relations=self.inspect(bom=[edge],alter=lambda goods,attributes,excel:goods[0].update(name="正常塑件（不再生产）"))
        self.assertEqual(relations,[])
        self.assertEqual(audit[0]["state"],"ALREADY_DEFINED_ACTIVE_BOM")
        self.assertEqual(edge["qty"],"0.025")


PG_FIXTURE = """
BEGIN;
SET LOCAL uten.bootstrap_run_id='00000000-0000-4000-8000-000000000099';
CREATE TEMP TABLE legacy_migration_runs(run_id uuid,status text,migration_mode text,reconciliation_summary jsonb);
CREATE TEMP TABLE departments(id uuid,name text,is_deleted boolean);
CREATE TEMP TABLE goods(id uuid,legacy_id int,name text,material text,source_type text,owning_workshop_department_id uuid,
 is_deleted boolean,auto_created boolean,issue_method text,code text,model text,unit_id uuid,category_id uuid,status text);
CREATE TEMP TABLE units(id uuid,legacy_id int,name text);
CREATE TEMP TABLE unit_measurement_profiles(unit_id uuid,measurement_dimension text);
CREATE TEMP TABLE material_categories(id uuid,legacy_id int);
CREATE TEMP TABLE goods_bom_items(goods_id uuid,component_goods_id uuid,qty numeric,is_deleted boolean);
CREATE TEMP TABLE goods_material_identity_evidence(id uuid default gen_random_uuid(),product_goods_id uuid,material_goods_id uuid,
 material_color_id uuid,source_kind text,status text,provenance jsonb,import_run_id uuid,created_by uuid,updated_by uuid,is_deleted boolean default false);
CREATE UNIQUE INDEX temp_identity_unique ON goods_material_identity_evidence(product_goods_id,material_goods_id,material_color_id)
 NULLS NOT DISTINCT WHERE NOT is_deleted;
INSERT INTO legacy_migration_runs VALUES('00000000-0000-4000-8000-000000000099','RUNNING','BOOTSTRAP','{}');
INSERT INTO departments VALUES('30000000-0000-4000-8000-000000000001','注塑车间',false);
INSERT INTO units VALUES('40000000-0000-4000-8000-000000000001',108,'kg');
INSERT INTO unit_measurement_profiles VALUES('40000000-0000-4000-8000-000000000001','MASS');
INSERT INTO material_categories VALUES('50000000-0000-4000-8000-000000000001',2120);
INSERT INTO goods VALUES
 ('10000000-0000-4000-8000-000000000001',52620,'1M三开中按钮','PC E-15','自制','30000000-0000-4000-8000-000000000001',false,false,'ORDER','1M0004','',NULL,NULL,'使用'),
 ('10000000-0000-4000-8000-000000000002',14533,'PC面板料E-15','PC','采购',NULL,false,false,'ORDER','280501002','E-15','40000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','使用');
"""


class InjectionMaterialSqlPostgresTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container="uten-material-role-tests-"+uuid.uuid4().hex[:12]
        result=subprocess.run(["docker","run","--detach","--rm","--network","none","--name",cls.container,
                               "-e","POSTGRES_HOST_AUTH_METHOD=trust","postgres:16-alpine"],capture_output=True)
        if result.returncode:
            raise RuntimeError("isolated PostgreSQL test container could not start")
        cls.addClassCleanup(lambda:subprocess.run(["docker","rm","-f","-v",cls.container],capture_output=True))
        for _ in range(60):
            ready=subprocess.run(["docker","exec",cls.container,"pg_isready","-U","postgres"],capture_output=True)
            if ready.returncode==0:
                return
            time.sleep(0.5)
        raise RuntimeError("isolated PostgreSQL test container was not ready")

    def run_loader(self, mutation="", *, expected_error=None, repeat=False, stage_mutation="", relations=None):
        relations = default_relations() if relations is None else relations
        stage_insert = "INSERT INTO injection_material_identity_stage VALUES" + ",".join(
            "("+row["product_legacy_id"]+","+row["material_legacy_id"]+",0,'LEGACY_MATERIAL_TEXT','PENDING_QUANTITY',"+
            subject.sql_literal(row["provenance"])+"::jsonb)" for row in relations)+";"+stage_mutation
        loader = re.sub(r"^\\copy.*$", lambda match: stage_insert, subject.render_loader(relations), flags=re.MULTILINE)
        assertion = """
DO $$ BEGIN
 IF (SELECT count(*) FROM goods_material_identity_evidence)<>EXPECTED_ROWS
 OR EXISTS(SELECT 1 FROM goods WHERE issue_method<>'ORDER')
 OR EXISTS(SELECT 1 FROM goods_bom_items)
 OR (SELECT reconciliation_summary#>>'{injectionMaterialIdentities,matchedRelations}' FROM legacy_migration_runs)<>'EXPECTED_ROWS'
 THEN RAISE EXCEPTION 'incorrect neutral load or changed executable facts'; END IF;
END; $$;
ROLLBACK;
"""
        assertion = assertion.replace("EXPECTED_ROWS", str(len(relations)))
        sql = PG_FIXTURE + mutation + loader
        if repeat:
            sql += "DROP TABLE injection_material_identity_stage; DROP TABLE approved_material_identity_stage;" + loader
        result = subprocess.run(["docker", "exec", "-i", self.container, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"],
                                input=(sql + assertion).encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        error = result.stderr.decode("utf-8", errors="replace")
        if expected_error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected_error, error)
        else:
            self.assertEqual(result.returncode, 0, error)

    def test_running_base_run_loads_neutral_identity_without_bom_or_issue_changes(self):
        self.run_loader()

    def test_repeated_load_is_idempotent(self):
        self.run_loader(repeat=True)

    def test_succeeded_base_run_is_supported_for_separate_stage(self):
        self.run_loader("UPDATE legacy_migration_runs SET status='SUCCESS';")

    def test_unapproved_workshop_fails(self):
        self.run_loader("UPDATE departments SET name='装配车间';", expected_error="imported product/workshop")

    def test_failed_base_claim_cannot_receive_evidence(self):
        self.run_loader("UPDATE legacy_migration_runs SET status='FAILED';", expected_error="explicit base import run")

    def test_existing_user_evidence_is_not_overwritten(self):
        self.run_loader("INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,status,provenance,import_run_id) "
                        "SELECT p.id,m.id,'USER_CONFIRMED','PENDING_QUANTITY','{\"user\":true}',r.run_id FROM goods p,goods m,legacy_migration_runs r "
                        "WHERE p.legacy_id=52620 AND m.legacy_id=14533;", expected_error="do not overwrite user")

    def test_sealed_mapping_rejects_modified_source_provenance(self):
        self.run_loader(stage_mutation="UPDATE injection_material_identity_stage SET provenance=jsonb_set(provenance,'{raw_goods,path}','\"tampered.csv\"');",
                        expected_error="sealed approved mapping set")

    def test_disabled_material_cannot_be_imported_even_with_original_approval(self):
        self.run_loader("UPDATE goods SET status='禁用' WHERE legacy_id=14533;", expected_error="imported product/workshop")

    def test_mass_unit_dimension_must_be_proven_in_target(self):
        self.run_loader("UPDATE unit_measurement_profiles SET measurement_dimension='COUNT';", expected_error="imported product/workshop")

    def test_reviewed_recycled_raw_identity_is_accepted_without_substring_rejection(self):
        goods,attributes,excel,raw,bindings=fixture("POM黑色（再生料）")
        goods[1].update(name="POM黑色（再生料）",material="POM")
        # Use a distinct raw ID; PC14533 retains its user-confirmed virgin semantics.
        goods[1]["legacy_id"]="14550"
        relations=inspect_fixture(goods,attributes,[],excel,raw,bindings)[1]
        self.assertEqual(len(relations),1)
        self.run_loader("UPDATE goods SET material='POM黑色（再生料）' WHERE legacy_id=52620; "
                        "UPDATE goods SET legacy_id=14550,name='POM黑色（再生料）',material='POM' WHERE legacy_id=14533;",
                        relations=relations)

    def test_multiple_material_types_are_loaded_without_a_single_material_id_assumption(self):
        goods, attributes, excel, raw, bindings = fixture()
        product = {**goods[0], "legacy_id": "52621", "code": "P2", "name": "G7注塑件", "material": "PC G-7"}
        material = {"legacy_id": "38224", "code": "RAW-G7", "name": "PC米黄色原料", "model": "G-7", "material": "PC", "unit_legacy_id": "108", "parent_legacy": "2120", "status": "使用"}
        goods.extend([product, material])
        attributes.append({**attributes[0], "legacy_id": "52621"})
        excel["p2"] = {**excel["1m0004"], "row": 7, "values": {**excel["1m0004"]["values"], "产品编号": "P2", "材质": "PC G-7"}}
        relations = inspect_fixture(goods, attributes, [], excel, raw, bindings)[1]
        extra = """INSERT INTO goods VALUES
 ('10000000-0000-4000-8000-000000000003',52621,'G7注塑件','PC G-7','自制','30000000-0000-4000-8000-000000000001',false,false,'ORDER','P2','',NULL,NULL,'使用'),
 ('10000000-0000-4000-8000-000000000004',38224,'PC米黄色原料','PC','采购',NULL,false,false,'ORDER','RAW-G7','G-7','40000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','使用');"""
        self.run_loader(extra, relations=relations)


if __name__ == "__main__":
    unittest.main()
