"""Prepare a verified private copy of Flutter 3.44.2's Android Gradle tooling.

The installed SDK and pub cache are never edited. The copy preserves the pinned
Flutter engine and Dart compiler; only the Gradle sources listed below change.
No warning filters or new suppression annotations are added.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


FLUTTER_REVISION = "c9a6c484230f8b5e408ec57be1ef71dee1e77020"
SOURCE_HASHES = {
    "build.gradle.kts": "e68e4e0e16acad8cd333ac54e061c76fdd0f95a19faf144443440354a420a3a4",
    "src/main/kotlin/Deeplink.kt": "5640a2f351c3130da1c8d89a584f8503a9f163bc9df2fd2f9eb28838c9ffe55c",
    "src/main/kotlin/plugins/PluginHandler.kt": "2e0aabbee4b6699ded8fb75fa38347d1fe6d1c719051a2177bfc6ea7595b4817",
    "src/main/kotlin/FlutterPlugin.kt": "f8fc0e97adf2c492ed519bee5fb2b6cc2d00e6ff8ccd42a78f6ba506cac5fa80",
    "src/main/kotlin/FlutterPluginUtils.kt": "4edac47ab150a5e3f6c1ffb7b75bada24e5e5e96bd2e568caf5551cf51d4945d",
}
ANDROID_PLUGINS = {
    "file_picker": ("8.3.7", "f407f99bc9c6daf2cd4bb3680c6df407b7258e39e7b481e08d640a0517915777", (
        ("group 'com.mr.flutter.plugin.filepicker'", "group = 'com.mr.flutter.plugin.filepicker'"),
        ("version '1.0-SNAPSHOT'", "version = '1.0-SNAPSHOT'"),
        ("    compileSdk 34", "    compileSdk = 34"),
        ("        minSdk 21", "        minSdk = 21"),
        ("        namespace 'com.mr.flutter.plugin.filepicker'", "        namespace = 'com.mr.flutter.plugin.filepicker'"),
    )),
    "flutter_secure_storage": ("9.2.4", "fd69c260d8c1af9ed6baa65928d32ba396fff05c3071cab02b29ab81cd4ce535", (
        ("group 'com.it_nomads.fluttersecurestorage'", "group = 'com.it_nomads.fluttersecurestorage'"),
        ("version '1.0-SNAPSHOT'", "version = '1.0-SNAPSHOT'"),
        ('        namespace("com.it_nomads.fluttersecurestorage")', '        namespace = "com.it_nomads.fluttersecurestorage"'),
        ("    compileSdk 34", "    compileSdk = 34"),
    )),
    "printing": ("5.15.1", "d82ce58961d67457c1e655f64d20350e7f2fb977096e6709d39104cc04613d13", (
        ('group "net.nfet.flutter.printing"', 'group = "net.nfet.flutter.printing"'),
        ('version "1.0"', 'version = "1.0"'),
    )),
}


def source_text(path: Path) -> str:
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def replace(text: str, old: str, new: str, count: int = 1) -> str:
    if text.count(old) != count:
        raise ValueError("Pinned Flutter patch context no longer matches")
    return text.replace(old, new)


def patched_sources(source: Path) -> dict[str, str]:
    texts = {name: source_text(source / name) for name in SOURCE_HASHES}
    for name, original in texts.items():
        if digest(original) != SOURCE_HASHES[name]:
            raise ValueError(f"Pinned Flutter source checksum mismatch: {name}")

    # kotlin-dsl already applies its supported embedded Kotlin compiler. The SDK
    # redundantly replaces it with another compiler, causing the mismatch warning.
    texts["build.gradle.kts"] = replace(
        texts["build.gradle.kts"], '    kotlin("jvm") version "2.2.20"\n', "")
    name = "src/main/kotlin/Deeplink.kt"
    texts[name] = replace(texts[name], "    @VisibleForTesting\n", "    @param:VisibleForTesting\n", 4)

    name = "src/main/kotlin/plugins/PluginHandler.kt"
    texts[name] = replace(texts[name], "import org.gradle.api.NamedDomainObjectContainer\n", "")
    texts[name] = replace(texts[name], "import com.android.build.gradle.internal.dsl.BuildType as dslBuildType\n", "")
    texts[name] = replace(texts[name],
        """                (getLegacyAndroidExtension(pluginProject).buildTypes as NamedDomainObjectContainer<dslBuildType>)
                    .addAll(getLegacyAndroidExtension(project).buildTypes as NamedDomainObjectContainer<dslBuildType>)""",
        """                val pluginBuildTypes = FlutterPluginUtils.getAndroidApplicationExtension(pluginProject).buildTypes
                FlutterPluginUtils.getAndroidApplicationExtension(project).buildTypes.forEach { appBuildType ->
                    val pluginBuildType = pluginBuildTypes.findByName(appBuildType.name)
                        ?: pluginBuildTypes.create(appBuildType.name)
                    pluginBuildType.initWith(appBuildType)
                }""")

    name = "src/main/kotlin/FlutterPluginUtils.kt"
    texts[name] = replace(texts[name], "import com.android.build.gradle.api.BaseVariantOutput\n", "")
    # AppLink tasks already use SingleArtifact.MERGED_MANIFEST. This obsolete
    # helper has no callers anywhere in the pinned Gradle tooling source tree.
    texts[name] = replace(texts[name],
        """    // TODO(gmackall): Migrate to AGPs variant api.
    //    https://github.com/flutter/flutter/issues/166550
    @Suppress("DEPRECATION")
    private fun findProcessResources(baseVariantOutput: BaseVariantOutput): ProcessAndroidResources =
        baseVariantOutput.processResourcesProvider?.get() ?: baseVariantOutput.processResources

""", "")

    name = "src/main/kotlin/FlutterPlugin.kt"
    texts[name] = replace(texts[name], "import com.android.build.gradle.api.ApkVariant\n", "")
    texts[name] = replace(texts[name],
        """            val appExtension = FlutterPluginUtils.getAndroidApplicationExtension(projectToAddTasksTo)
            configureAbis(projectToAddTasksTo, appExtension)""",
        """            val appExtension = FlutterPluginUtils.getAndroidApplicationExtension(projectToAddTasksTo)
            configureAbis(projectToAddTasksTo, appExtension)
            if (FlutterPluginUtils.shouldProjectSplitPerAbi(projectToAddTasksTo)) {
                val components = projectToAddTasksTo.extensions.getByType(
                    com.android.build.api.variant.ApplicationAndroidComponentsExtension::class.java
                )
                components.onVariants { variant ->
                    variant.outputs.forEach { output ->
                        val abi = output.filters.find {
                            it.filterType == com.android.build.api.variant.FilterConfiguration.FilterType.ABI
                        }?.identifier
                        val abiVersionCode = FlutterPluginConstants.ABI_VERSION[abi]
                        if (abiVersionCode != null) {
                            val baseVersionCode = output.versionCode.get()
                            output.versionCode.set(abiVersionCode * 1000 + baseVersionCode)
                        }
                    }
                }
            }""")
    texts[name] = replace(texts[name],
        """            if (FlutterPluginUtils.shouldProjectSplitPerAbi(project)) {
                variant.outputs.forEach { output ->
                    // need to force this as the API does not return the right thing for our use.
                    // TODO(gmackall): Migrate to AGPs variant api.
                    //    https://github.com/flutter/flutter/issues/166550
                    @Suppress("DEPRECATION")
                    output as com.android.build.gradle.api.ApkVariantOutput
                    val versionCodeIfPresent: Int? = if (variant is ApkVariant) variant.versionCode else null

                    // TODO(gmackall): Migrate to AGPs variant api.
                    //    https://github.com/flutter/flutter/issues/166550
                    @Suppress("DEPRECATION")
                    val filterIdentifier: String? =
                        output.getFilter(com.android.build.VariantOutput.FilterType.ABI)
                    val abiVersionCode: Int? = FlutterPluginConstants.ABI_VERSION[filterIdentifier]
                    if (abiVersionCode != null) {
                        output.versionCodeOverride = abiVersionCode * 1000 + (
                            versionCodeIfPresent
                                ?: variant.mergedFlavor.versionCode as Int
                        )
                    }
                }
            }

""", "")
    return texts


def prepare(sdk: Path, output: Path) -> dict:
    sdk, output = sdk.resolve(strict=True), output.resolve()
    if output == sdk or sdk in output.parents or output in sdk.parents:
        raise ValueError("Private tooling output must be outside the installed Flutter SDK")
    version = json.loads((sdk / "bin/cache/flutter.version.json").read_text(encoding="utf-8"))
    if version.get("frameworkVersion") != "3.44.2" or version.get("frameworkRevision") != FLUTTER_REVISION:
        raise ValueError("The private tooling recipe requires the pinned Flutter 3.44.2 revision")
    revision = subprocess.run(["git", "-C", str(sdk), "rev-parse", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
    if revision != FLUTTER_REVISION:
        raise ValueError("Installed Flutter checkout revision differs from its cached version")
    result = subprocess.run(["git", "-C", str(sdk), "diff", "--quiet", "--", "packages/flutter_tools/gradle"],
                            check=False, capture_output=True)
    if result.returncode != 0:
        raise ValueError("Installed Flutter Gradle sources have local changes; preserve and review them first")
    source = sdk / "packages/flutter_tools/gradle"
    texts = patched_sources(source)
    receipt = {"flutterVersion": "3.44.2", "frameworkRevision": FLUTTER_REVISION,
               "upstreamHashes": SOURCE_HASHES,
               "patchedHashes": {name: digest(text) for name, text in texts.items()}}
    receipt_path = output / "uten-tooling-receipt.json"
    if output.exists():
        if (not receipt_path.is_file() or json.loads(receipt_path.read_text(encoding="utf-8")) != receipt
                or any(digest(source_text(output / name)) != receipt["patchedHashes"][name] for name in texts)):
            raise ValueError("Existing private tooling differs; use a new task-owned output directory")
        return receipt
    shutil.copytree(source, output, ignore=shutil.ignore_patterns(".gradle", ".kotlin", "build"))
    shutil.copy2(sdk / "LICENSE", output / "FLUTTER-LICENSE")
    for name, text in texts.items():
        (output / name).write_text(text, encoding="utf-8", newline="\n")
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return receipt


def prepare_android_plugins(project: Path, output: Path) -> dict:
    """Keep pinned native plugin sources private without changing Dart resolution."""
    dependencies = json.loads((project / ".flutter-plugins-dependencies").read_text(encoding="utf-8"))
    android = {entry["name"]: entry for entry in dependencies["plugins"]["android"]}
    receipt = {}
    plans = {}
    for name, (version, original_hash, replacements) in ANDROID_PLUGINS.items():
        if name not in android:
            raise ValueError(f"Pinned Android plugin is missing from the generated dependency inventory: {name}")
        source = Path(android[name]["path"]).resolve(strict=True)
        declared_version = re.search(r"(?m)^version:\s*([^\s]+)", source_text(source / "pubspec.yaml"))
        if not declared_version or declared_version.group(1).strip("\"'") != version:
            raise ValueError(f"Pinned Android plugin version changed: {name}")
        original = source_text(source / "android/build.gradle")
        if digest(original) != original_hash:
            raise ValueError(f"Pinned Android plugin source checksum changed: {name}")
        patched = original
        for old, new in replacements:
            patched = replace(patched, old, new)
        receipt[name] = {"version": version, "upstreamBuildHash": original_hash,
                         "patchedBuildHash": digest(patched)}
        plans[name] = source, patched
    manifest = output / "manifest.json"
    if output.exists():
        if (not manifest.is_file() or json.loads(manifest.read_text(encoding="utf-8")) != receipt
                or any(digest(source_text(output / name / "android/build.gradle")) != entry["patchedBuildHash"]
                       for name, entry in receipt.items())):
            raise ValueError("Existing private Android plugins differ; use a new task-owned tooling directory")
        return receipt
    output.mkdir(parents=True)
    for name, (source, patched) in plans.items():
        shutil.copytree(source, output / name,
                        ignore=shutil.ignore_patterns(".gradle", ".dart_tool", ".kotlin", ".git", "build"))
        (output / name / "android/build.gradle").write_text(patched, encoding="utf-8", newline="\n")
    manifest.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        receipt = prepare(args.flutter_sdk, args.output)
        native = prepare_android_plugins(args.project_root, args.output / "uten-android-plugins")
    except (OSError, ValueError, subprocess.SubprocessError) as failure:
        parser.exit(1, f"Android tooling preparation rejected: {failure}\n")
    print(json.dumps({"output": str(args.output.resolve()), **receipt, "androidPlugins": native}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
