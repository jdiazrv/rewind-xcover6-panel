import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Read straight from pubspec.yaml instead of trusting `flutter.versionCode`/
// `flutter.versionName` (sourced from android/local.properties): those two
// are only rewritten by the `flutter` CLI's own build/run commands, and this
// project routinely builds via `./gradlew assembleRelease`/`bundleRelease`
// directly (a `flutter build apk` bug makes it fail silently) — so
// local.properties goes stale and every direct-Gradle build keeps stamping
// whatever version was last set by an actual `flutter build`/`run`.
val pubspecVersion = rootProject
    .file("../pubspec.yaml")
    .readLines()
    .first { it.trim().startsWith("version:") }
    .substringAfter("version:")
    .trim()
val pubspecVersionName = pubspecVersion.substringBefore("+")
val pubspecVersionCode = pubspecVersion.substringAfter("+").toInt()

android {
    namespace = "com.rewindpanel.myapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.rewindpanel.myapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = pubspecVersionCode
        versionName = pubspecVersionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Used to silently fall back to the debug keys when
            // key.properties/the keystore were missing — meant as a
            // fresh-checkout convenience, but it meant a release build could
            // end up debug-signed with no warning at all (Play Console would
            // catch it on upload, but a sideloaded APK/AAB — this project's
            // actual distribution path — never gets that check). Fail loudly
            // instead: a real release key is a one-time setup, not something
            // that should ever be silently substituted.
            if (!keystorePropertiesFile.exists()) {
                throw GradleException(
                    "android/key.properties not found — release builds must be " +
                    "signed with the real upload keystore, not the debug key. " +
                    "See android/key.properties.example (or the project README) " +
                    "for how to set it up."
                )
            }
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
