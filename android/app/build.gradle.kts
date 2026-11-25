plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dhanunjay.dj"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dhanunjay.dj"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// NOTE: the kotlin {} block MUST stay top-level (outside android {}).
// It is the Kotlin Gradle plugin's project extension, not a member of
// the AGP android {} block. Commit 3c4e729 put it nested inside
// android {} — Google's migration guide
// (developer.android.com/build/migrate-to-built-in-kotlin) and the
// Firebase plugins' own build files both use this top-level form, and
// a nested kotlin {} block risks a configuration-time failure
// ("unresolved reference: kotlin") on the next CI run. jvmTarget stays
// JVM_11, matching compileOptions above; only the placement changed.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}
