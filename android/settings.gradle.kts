pluginManagement {
    // Force the Kotlin Gradle plugin to 2.3.0 for EVERY plugin id that
    // requests it — the full id and the legacy "kotlin-android" alias.
    // Root cause of the v1.2.3 :app:compileReleaseKotlin failure: the
    // app applied the "kotlin-android" alias, which has no plugin
    // marker artifact, so pluginManagement could not version-resolve
    // it and Gradle fell back to the buildscript classpath, where the
    // only kotlin-gradle-plugin was 2.1.0 (face_detection_tflite's
    // legacy Groovy buildscript: ext.kotlin_version = "2.1.0").
    // The 2.1.0 compiler then could not read firebase_core/auth/
    // firestore's 2.3.0 metadata. This rule makes 2.3.0 win for any
    // module that asks for the Kotlin plugin, whatever id it uses.
    resolutionStrategy {
        eachPlugin {
            if (requested.id.id == "org.jetbrains.kotlin.android" ||
                requested.id.id == "kotlin-android"
            ) {
                useVersion("2.3.0")
            }
        }
    }

    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.0" apply false
}

include(":app")
