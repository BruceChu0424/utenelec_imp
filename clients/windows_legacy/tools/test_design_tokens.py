"""Cross-language design contracts, strict parsing, and read-only drift checks."""
from decimal import Decimal
import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

import sync_design_tokens as sync

ROOT = Path(__file__).resolve().parents[3]


class DesignTokenTests(unittest.TestCase):
    def texts(self):
        return {path: (ROOT / path).read_text(encoding="utf-8") for path in sync.SOURCES}

    def values(self, texts=None):
        return {entry["key"]: entry for entry in sync.build_resources(sync.DartTokens(texts or self.texts()))}

    def test_reviewed_radius_and_control_roles(self):
        values = self.values()
        radii = {"Xs": "4", "Small": "6", "Medium": "8", "Control": "10", "Menu": "8",
                 "Table": "12", "Card": "16", "Dialog": "20", "Pill": "999"}
        for role, expected in radii.items():
            with self.subTest(role=role):
                self.assertEqual(values["Uten.Radius." + role]["value"], expected)
                self.assertEqual(values["Uten.Radius." + role + "Value"]["value"], expected)
        for role, expected in {"Compact": "36", "Standard": "40", "Primary": "48", "Input": "44", "Cell": "32"}.items():
            self.assertEqual(values["Uten.Height." + role]["value"], expected)
            self.assertNotIn("Uten.Height." + role + expected, values)
        self.assertIn("not a table row", values["Uten.Height.Cell"]["note"])

    def test_aliases_resolve_the_owning_constants_and_reject_cycles(self):
        texts = self.texts()
        texts[sync.SOURCES[0]] = texts[sync.SOURCES[0]].replace("static const double md = 8;", "static const double md = 9;")
        values = self.values(texts)
        self.assertEqual(values["Uten.Radius.Menu"]["value"], "9")
        self.assertEqual([step["symbol"] for step in values["Uten.Radius.Menu"]["resolution"]], ["UtenRadius.menu", "UtenRadius.md"])
        texts[sync.SOURCES[0]] = texts[sync.SOURCES[0]].replace("static const double md = 9;", "static const double md = menu;")
        with self.assertRaisesRegex(sync.TokenError, "cycle"):
            self.values(texts)

    def test_primary_semantics_follow_light_theme_not_compatibility_palette(self):
        texts = self.texts()
        values = self.values(texts)
        self.assertEqual(values["Uten.PrimaryBrush"]["value"], "#FF0F766E")
        self.assertEqual(sync.DartTokens(texts).resolve("UtenColors.primary", "color")[0], "#FF14B8A6")
        texts[sync.SOURCES[2]] = texts[sync.SOURCES[2]].replace("primary: UtenColors.teal700,", "primary: UtenColors.teal600,", 1)
        self.assertEqual(self.values(texts)["Uten.PrimaryBrush"]["value"], "#FF0D9488")

    def test_semantic_padding_and_caption_are_parsed_from_actual_widgets(self):
        values = self.values()
        for key, expected in {"Button": "16,8,16,8", "Input": "12,10,12,10", "Filter": "8,4,8,4", "CaptionHorizontal": "8,0,8,0"}.items():
            self.assertEqual(values["Uten.Padding." + key]["value"], expected)
        self.assertEqual(values["Uten.Height.Caption"]["value"], "36")
        self.assertNotIn("Uten.Height.Caption36", values)
        for key, expected in {"HitWidth": "30", "Diameter": "22", "IconSize": "14", "Minimize": "#FFF59E0B", "Close": "#FFEF4444"}.items():
            self.assertEqual(values["Uten.Caption." + key]["value"], expected)
        self.assertEqual(values["Uten.Error"]["value"], "#FFB91C1C")

    def test_button_padding_difference_is_not_silently_unified(self):
        texts = self.texts()
        light = texts[sync.SOURCES[2]]
        offset = light.index("outlinedButtonTheme:")
        texts[sync.SOURCES[2]] = light[:offset] + light[offset:].replace("horizontal: 16, vertical: 8", "horizontal: 20, vertical: 8", 1)
        with self.assertRaisesRegex(sync.TokenError, "padding diverged"):
            self.values(texts)

    def test_login_brand_surface_is_derived_not_copied_as_a_palette_literal(self):
        texts = self.texts()
        self.assertEqual(self.values(texts)["Uten.LoginBrandSurface"]["value"], "#FFF3F8F8")
        texts[sync.SOURCES[5]] = texts[sync.SOURCES[5]].replace("dark ? 0.04 : 0.05", "dark ? 0.04 : 0.10")
        self.assertNotEqual(self.values(texts)["Uten.LoginBrandSurface"]["value"], "#FFF3F8F8")

    def test_typography_roles_are_source_backed(self):
        values = self.values()
        for key, expected in {"Body": "14", "Value": "14", "Caption": "13", "Title": "18", "Subtitle": "16", "Heading": "24", "Input": "16", "Compact": "14"}.items():
            self.assertEqual(values["Uten.FontSize." + key]["value"], expected)
        texts = self.texts()
        texts[sync.SOURCES[3]] = texts[sync.SOURCES[3]].replace("fontSize: size,", "fontSize: size * 2,")
        with self.assertRaisesRegex(sync.TokenError, "Unsupported text helper"):
            self.values(texts)

    def test_missing_and_unparsed_values_never_get_fallbacks(self):
        for replacement in ("", "static const double control = 8 + 2;", "static const double control = missing;"):
            texts = self.texts()
            texts[sync.SOURCES[0]] = texts[sync.SOURCES[0]].replace("static const double control = 10;", replacement)
            with self.subTest(replacement=replacement), self.assertRaises(sync.TokenError):
                self.values(texts)

    def test_all_source_spacing_roles_exist_as_double_and_uniform_thickness(self):
        tokens = sync.DartTokens(self.texts())
        values = self.values()
        for symbol in tokens.declarations:
            if symbol.startswith("UtenSpacing."):
                suffix = symbol.split(".")[1].capitalize()
                expected = tokens.resolve(symbol, "number")[0]
                self.assertEqual(Decimal(values["Uten.Space." + suffix]["value"]), expected)
                self.assertEqual(Decimal(values["Uten.Padding." + suffix]["value"]), expected)
        texts = self.texts()
        texts[sync.SOURCES[0]] = texts[sync.SOURCES[0]].replace("static const double s16 = 16;", "")
        with self.assertRaisesRegex(sync.TokenError, "UtenSpacing.s16"):
            self.values(texts)

    def test_check_detects_output_and_source_drift_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for source in sync.SOURCES:
                target = root / source
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((ROOT / source).read_bytes())
            sync.write(root)
            sync.check(root)
            resource = root / sync.RESOURCE
            resource.write_bytes(resource.read_bytes().replace(b">10</CornerRadius>", b">11</CornerRadius>", 1))
            before = resource.read_bytes()
            with self.assertRaisesRegex(sync.TokenError, "drift"):
                sync.check(root)
            self.assertEqual(resource.read_bytes(), before)
            sync.write(root)
            source = root / sync.SOURCES[0]
            source.write_bytes(source.read_bytes().replace(b"control = 10;", b"control = 11;"))
            with self.assertRaisesRegex(sync.TokenError, "drift"):
                sync.check(root)

    def test_resources_use_net48_types_and_provenance_tracks_every_key(self):
        rendered = sync.artifacts(ROOT)
        dictionary = ET.fromstring(rendered[sync.RESOURCE])
        key_name = "{http://schemas.microsoft.com/winfx/2006/xaml}Key"
        keys = [item.attrib[key_name] for item in dictionary]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(any(item.tag == "{clr-namespace:System;assembly=mscorlib}Double" for item in dictionary))
        provenance = json.loads(rendered[sync.PROVENANCE])
        self.assertEqual(set(keys), {item["key"] for item in provenance["roleMappings"]})
        self.assertEqual({item["path"] for item in provenance["sources"]}, set(sync.SOURCES))
        for item in provenance["roleMappings"]:
            self.assertTrue(item["resolution"])


if __name__ == "__main__":
    unittest.main()
