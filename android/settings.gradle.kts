pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    val flutterGradleTools = providers.gradleProperty("utenFlutterGradleTools").orNull
        ?: "$flutterSdkPath/packages/flutter_tools/gradle"
    includeBuild(flutterGradleTools)

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("com.android.library") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// The verified preparation recipe copies only the three reviewed native plugin
// projects that need Groovy assignment fixes. Dart keeps its original lock and
// package paths; the shared pub cache is never edited.
providers.gradleProperty("utenFlutterGradleTools").orNull?.let { tooling ->
    val privatePlugins = File(tooling, "uten-android-plugins")
    check(File(privatePlugins, "manifest.json").isFile) {
        "Run prepare_android_flutter_tooling.py before using private Android tooling."
    }
    rootProject.children.forEach { descriptor ->
        val androidSource = File(privatePlugins, "${descriptor.name}/android")
        if (androidSource.isDirectory) descriptor.projectDir = androidSource
    }
}
