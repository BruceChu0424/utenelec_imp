from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

RES = Path(__file__).resolve().parents[2] / "android/app/src/main/res"


def resolved_theme(night, api):
    directory = "values-night" if night else "values"
    styles = {}
    for suffix in ("", *(["-v26"] if api >= 26 else []), *(["-v29"] if api >= 29 else [])):
        document = ET.parse(RES / (directory + suffix) / "styles.xml")
        for style in document.getroot().findall("style"):
            styles[style.attrib["name"]] = style

    def resolve(name):
        style = styles[name]
        parent = style.attrib.get("parent", "")
        items = resolve(parent) if parent in styles else {}
        return {**items, **{item.attrib["name"]: item.text for item in style.findall("item")}}
    return resolve


class AndroidSystemBarThemeTest(unittest.TestCase):
    def test_startup_and_flutter_windows_share_api_appropriate_system_bar_policy(self):
        for night in (False, True):
            for api in (24, 25, 26, 28, 29, 35, 36):
                with self.subTest(night=night, api=api):
                    resolve = resolved_theme(night, api)
                    for name in ("LaunchTheme", "NormalTheme"):
                        items = resolve(name)
                        self.assertEqual("@android:color/transparent", items["android:statusBarColor"])
                        self.assertEqual("@android:color/black" if api < 26 else "@android:color/transparent",
                                         items["android:navigationBarColor"])
                        if api >= 26:
                            self.assertEqual("false" if night else "true", items["android:windowLightNavigationBar"])
                        if api >= 29:
                            self.assertEqual("false", items["android:enforceNavigationBarContrast"])
                            self.assertEqual("false", items["android:enforceStatusBarContrast"])
                        self.assertNotIn("android:windowOptOutEdgeToEdgeEnforcement", items)
                        self.assertNotIn("android:windowFullscreen", items)


if __name__ == "__main__":
    unittest.main()
