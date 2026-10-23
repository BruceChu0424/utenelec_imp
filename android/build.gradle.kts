import com.android.build.api.variant.LibraryAndroidComponentsExtension

plugins {
    id("com.android.library") apply false
}

// One compile API baseline for the app and every Android library. The locked
// lifecycle plugin requires API 36 even when an older consumer pins API 34.
val androidCompileSdk = 36
extra["utenCompileSdk"] = androidCompileSdk

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<LibraryAndroidComponentsExtension> {
            // Run after the plugin's own DSL so a legacy compileSdk assignment
            // cannot lower the shared API required by transitive AAR metadata.
            finalizeDsl { library -> library.compileSdk = androidCompileSdk }
        }
    }
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
