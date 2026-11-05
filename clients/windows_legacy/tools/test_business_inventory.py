import copy
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import business_inventory as inventory
import module_coverage


class BusinessInventoryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wpf page source fixture ")
        self.root = Path(self.temporary.name)
        self.patch = mock.patch.object(inventory, "ROOT", self.root)
        self.patch.start()
        self.write(inventory.ROUTE_NAMES, "abstract class RouteName { static const String old = '/old'; }")
        self.write(inventory.ENDPOINTS, "abstract class ApiEndpoints {}")
        self.write(inventory.PERMISSIONS, "abstract class Perm {}")
        self.write(inventory.ROUTER, "final router = GoRouter(routes: []);")

    def tearDown(self):
        self.patch.stop()
        self.temporary.cleanup()

    def write(self, source, text):
        path = self.root / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_singular_and_plural_sources_share_one_sorted_discovery_without_helpers(self):
        for name in ["old_page.dart", "bundle_pages.dart", "page_factory.dart", "page_helpers.dart"]:
            self.write("lib/features/fixture/pages/" + name, "class FixturePage {}")
        expected = ["bundle_pages.dart", "old_page.dart"]
        self.assertEqual(expected, [path.name for path in inventory.page_source_paths()])
        with mock.patch.object(module_coverage, "ROOT", self.root):
            result = module_coverage.collect()
        self.assertEqual(expected, [Path(item["source"]).name for item in result["pageEntrypoints"]])
        self.assertFalse(result["releaseReady"])
        self.assertEqual(0, result["summary"]["fullyMigratedBusinessWorkflows"])

    def test_plural_companion_keeps_multiple_classes_routes_named_constructor_and_old_source(self):
        old = "lib/features/fixture/pages/old_page.dart"
        plural = "lib/features/fixture/pages/bundle_pages.dart"
        self.write(old, "class OldPage {}")
        self.write(inventory.ROUTER, """
import '../../features/fixture/pages/old_page.dart';
import '../../features/fixture/pages/bundle_pages.dart' as companion;
final router = GoRouter(routes: [
  GoRoute(path: RouteName.old, builder: (_, _) => OldPage()),
  GoRoute(path: '/list', builder: (_, _) => companion.ListPage()),
  GoRoute(path: '/detail/:id', builder: (_, s) => companion.DetailPage(id: s.id)),
  GoRoute(path: '/history', builder: (_, _) => companion.ListPage.history()),
]);
""")
        before = copy.deepcopy(inventory.collect()["pages"][0])
        self.write(plural, "class ListPage {}\nclass DetailPage {}\nclass _State {}")
        result = inventory.collect()
        pages = {page["source"]: page for page in result["pages"]}
        self.assertEqual(before, pages[old], "An added companion must not replace an original owning source")
        self.assertEqual("page:fixture/pages/bundle_pages.dart", pages[plural]["id"])
        self.assertEqual({"/list", "/detail/:id", "/history"}, {route["path"] for route in pages[plural]["routerBindings"]})
        self.assertEqual({"companion.ListPage", "companion.DetailPage"},
                         {name for route in pages[plural]["routerBindings"] for name in route["builderClasses"]})
        self.assertEqual(2, result["summary"]["pageFiles"])
        self.assertIsNone(result["fullWorkflowCount"])
        self.assertTrue(result["interpretation"]["pageFilesAreNotWorkflows"])

    def test_direct_part_page_keeps_library_route_alias_and_visibility(self):
        library = "lib/features/fixture/pages/bundle_pages.dart"
        part = "lib/features/fixture/pages/bundle_create.dart"
        self.write(library, "part 'bundle_create.dart';\nclass ListPage {}")
        self.write(part, "part of 'bundle_pages.dart';\nclass CreatePage {}\nclass HiddenPage {}")
        self.write(inventory.ROUTER, """
import '../../features/fixture/pages/bundle_pages.dart' as companion hide HiddenPage;
final router = GoRouter(routes: [
  GoRoute(path: '/list', builder: (_, _) => companion.ListPage()),
  GoRoute(path: '/create', builder: (_, _) => companion.CreatePage()),
  GoRoute(path: '/hidden', builder: (_, _) => companion.HiddenPage()),
]);
""")
        result = inventory.collect()
        self.assertEqual(1, len(result["pages"]), "A direct part does not create another work package")
        page = result["pages"][0]
        self.assertEqual({"/list", "/create"}, {route["path"] for route in page["routerBindings"]})
        self.assertEqual(part, page["partUnits"][0]["source"])
        constructor = next(route for route in result["routerInventory"] if route["path"] == "/create")["constructedClasses"][0]
        self.assertEqual({library, part}, set(constructor["sources"]))

    def test_registered_route_fragment_has_its_own_source_but_import_only_routes_do_not_bind(self):
        plural = "lib/features/fixture/pages/bundle_pages.dart"
        fragment = "lib/features/fixture/fixture_routes.dart"
        self.write(plural, "class ListPage {}\nclass DetailPage {}")
        self.write(fragment, """
import 'pages/bundle_pages.dart';
final List<RouteBase> fixtureRoutes = [
  GoRoute(path: '/module/list', builder: (_, _) => ListPage()),
  GoRoute(path: '/module/:id', builder: (_, s) => DetailPage(id: s.id)),
];
final List<RouteBase> unregisteredSibling = [
  GoRoute(path: '/unregistered-sibling', builder: (_, _) => ListPage()),
];
""")
        self.write("lib/features/fixture/unused_routes.dart", """
import 'pages/bundle_pages.dart';
final List<RouteBase> unusedRoutes = [GoRoute(path: '/unused', builder: (_, _) => ListPage())];
""")
        self.write(inventory.ROUTER, """
import '../../features/fixture/fixture_routes.dart' as module;
import '../../features/fixture/unused_routes.dart';
final router = GoRouter(routes: [...module.fixtureRoutes]);
""")
        result = inventory.collect()
        routes = result["pages"][0]["routerBindings"]
        self.assertEqual({"/module/list", "/module/:id"}, {route["path"] for route in routes})
        self.assertTrue(all(route["routerSource"] == fragment for route in routes))
        self.assertTrue(all(route["routeId"].startswith("router:" + fragment + ":") for route in routes))
        self.assertNotIn("/unused", {route["path"] for route in result["routerInventory"]})
        self.assertNotIn("/unregistered-sibling", {route["path"] for route in result["routerInventory"]})

    def test_dynamic_factory_does_not_become_a_proven_page_binding(self):
        self.write("lib/features/fixture/pages/bundle_pages.dart", "class ListPage {}\nclass HistoryPage {}")
        self.write("lib/features/fixture/page_factory.dart", """
import 'pages/bundle_pages.dart';
abstract class PageFactory { static Widget list(bool history) => history ? HistoryPage() : ListPage(); }
""")
        self.write(inventory.ROUTER, """
import '../../features/fixture/page_factory.dart';
final router = GoRouter(routes: [GoRoute(path: '/:kind', builder: (_, s) => PageFactory.list(s.history))]);
""")
        page = inventory.collect()["pages"][0]
        self.assertEqual([], page["routerBindings"])
        self.assertTrue(any("动态factory" in flag for flag in page["reviewFlags"]))


class RepositoryPluralPageCoverageTest(unittest.TestCase):
    def test_all_real_plural_companions_and_registered_production_routes_are_preserved(self):
        result = inventory.collect()
        pages = {Path(page["source"]).name: page for page in result["pages"]}
        expected = {"subcontract_business_list_pages.dart": 0,
                    "procurement_return_task_pages.dart": 2,
                    "finance_arrival_exception_pages.dart": 2,
                    "production_over_limit_pages.dart": 2,
                    "production_overproduction_rate_pages.dart": 2,
                    "production_material_increment_pages.dart": 3}
        self.assertEqual(set(expected), {name for name in pages if name.endswith("_pages.dart")})
        for name, bindings in expected.items():
            with self.subTest(source=name):
                self.assertEqual(bindings, len(pages[name]["routerBindings"]))
                self.assertTrue(any(item["role"] == "page-class" for item in pages[name]["classes"]))
        self.assertTrue(all(path.relative_to(inventory.ROOT).as_posix() in {page["source"] for page in pages.values()}
                            for path in (inventory.ROOT / "lib/features").rglob("*_page.dart")))
        supplier = pages["procurement_return_task_pages.dart"]
        self.assertEqual({"/procurement/arrival-exceptions", "/procurement/arrival-exceptions/:id"},
                         {route["path"] for route in supplier["routerBindings"]})


if __name__ == "__main__":
    unittest.main()
