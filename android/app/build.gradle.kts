import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter passes --dart-define values to Gradle base64-encoded. STORE_BUILD=true
// makes the Google Play "store" build: see src/store/AndroidManifest.xml and docs/RELEASE.md.
val dartDefines: Map<String, String> = (project.findProperty("dart-defines") as String?)
    ?.split(",")
    ?.mapNotNull { runCatching { String(Base64.getDecoder().decode(it)) }.getOrNull() }
    ?.mapNotNull { d -> d.split("=", limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }
    ?.toMap() ?: emptyMap()
val isStoreBuild = dartDefines["STORE_BUILD"] == "true"

// Release signing: android/key.properties (never committed). See docs/RELEASE.md.
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keyProperties.getProperty("storeFile") != null

android {
    namespace = "app.sim_bulk_sms"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Final, published ID: never change it after release (the Kotlin package/namespace can differ).
        applicationId = "com.comeriver.simbulksms.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 36 // Google Play: required for new apps and updates since 31 Aug 2026
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "STORE_BUILD", isStoreBuild.toString())
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("android/key.properties not found: release build is signed with the DEBUG key. " +
                    "Google Play will reject it. See docs/RELEASE.md.")
                signingConfigs.getByName("debug")
            }
        }
    }

    // Store build: merge the overlay that removes SMS, phone-state, background-service
    // and battery-exemption permissions (release/profile; debug keeps the dev INTERNET overlay).
    if (isStoreBuild) {
        sourceSets.getByName("release").manifest.srcFile("src/store/AndroidManifest.xml")
        sourceSets.getByName("profile").manifest.srcFile("src/store/AndroidManifest.xml")
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

dependencies {
    // SmsBridge: ContextCompat.registerReceiver / ActivityCompat permission requests
    implementation("androidx.core:core-ktx:1.13.1")
}
