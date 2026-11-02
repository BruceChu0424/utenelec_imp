pluginManagement {
    // Dart's Windows environment map uppercases keys before Flutter launches
    // Gradle. Gradle project-property names remain case-sensitive. Resolve the
    // two known transport spellings once, and reject contradictory values.
    fun nativeBuildProperty(name: String): String? {
        val values = listOf(name, name.uppercase(java.util.Locale.ROOT))
            .mapNotNull { providers.gradleProperty(it).orNull }
            .distinct()
        check(values.size <= 1) { "Conflicting Android build property spellings: $name" }
        return values.singleOrNull()
    }
    val privateTooling = nativeBuildProperty("utenFlutterGradleTools")
    check(privateTooling == null || privateTooling.isNotBlank()) { "Private Android tooling path cannot be blank." }
    val localTest = nativeBuildProperty("utenLocalTest")
    check(localTest == null || localTest == "true" || localTest == "false") { "utenLocalTest must be true or false." }
    settings.gradle.extensions.extraProperties.set("utenResolvedFlutterGradleTools", privateTooling ?: "")
    settings.gradle.extensions.extraProperties.set("utenResolvedLocalTest", localTest == "true")
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    val flutterGradleTools = privateTooling
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

// The verified recipe prepares reviewed native source fixes and relocates
// foreign-volume Windows native inputs for Kotlin's relative-path caches.
// Dart keeps its original lock and package paths; the shared pub cache is not edited.
val privateTooling = gradle.extensions.extraProperties.get("utenResolvedFlutterGradleTools") as String
privateTooling.takeIf { it.isNotEmpty() }?.let { tooling ->
    val privatePlugins = File(tooling, "uten-android-plugins")
    check(File(privatePlugins, "manifest.json").isFile) {
        "Run prepare_android_flutter_tooling.py before using private Android tooling."
    }
    rootProject.children.forEach { descriptor ->
        val androidSource = File(privatePlugins, "${descriptor.name}/android")
        if (androidSource.isDirectory) descriptor.projectDir = androidSource
        if (System.getProperty("os.name").startsWith("Windows")) {
            check(descriptor.projectDir.canonicalFile.toPath().root == settingsDir.canonicalFile.toPath().root) {
                "Private native Android project must use the application volume: ${descriptor.path}"
            }
        }
    }
}
