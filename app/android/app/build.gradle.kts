// Release signing uses one fixed key, so an update installs over the existing app and keeps the wallet.
// The key never goes into git: tools/build.sh and CI pass it in through these environment variables
// (see tools/make-signing-key.sh). Without them, release builds fall back to the debug key.
val releaseKeystore: File? = System.getenv("BW_KEYSTORE")?.let { File(it) }?.takeIf { it.isFile }

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "hr.marcelic.budget_wallet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs Java 8+ time APIs on older Android versions.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "hr.marcelic.budget_wallet"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 64-bit only: ML Kit AARs bundle 32-bit ARM libs that --target-platform does not remove (about 10 MB).
    packaging {
        jniLibs {
            excludes += listOf("lib/armeabi-v7a/**", "lib/x86/**")
            // BW_APK_ABIS=arm64 (CI, published APK): phones only, no x86_64 emulator libs
            if (System.getenv("BW_APK_ABIS") == "arm64") excludes += "lib/x86_64/**"
        }
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = System.getenv("BW_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("BW_KEY_ALIAS")
                keyPassword = System.getenv("BW_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // R8: shrink code and resources explicitly (not left to the Flutter plugin default)
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName(if (releaseKeystore != null) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
