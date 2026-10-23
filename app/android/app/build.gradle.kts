// Release signing uses one fixed key, so an update installs over the existing app and keeps the wallet.
// The key never goes into git: tools/build.sh and CI pass it in through these environment variables
// (see tools/make-signing-key.sh). Without them a release build FAILS (check at the end of this file): there is no fallback
// to the debug key, because an APK signed with it cannot update the installed app and would force an uninstall, which wipes
// the wallet. Debug and profile builds are unaffected (Flutter signs them with the debug key).
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
            // Pinned explicitly; the Flutter plugin sets the same, so no size change is expected
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // No fallback: without the release key the build is stopped by the check at the end of this file.
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
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

// A release build needs the fixed release key. Checked once the task graph is known, so only a task that produces a release
// artifact fails (debug and profile builds, lint, tests and `flutter pub get` do not).
gradle.taskGraph.whenReady {
    val releaseTasks = setOf("assembleRelease", "bundleRelease", "packageRelease", "packageReleaseBundle", "validateSigningRelease")
    if (allTasks.any { it.project == project && it.name in releaseTasks }) {
        val missing = listOf("BW_KEYSTORE_PASSWORD", "BW_KEY_ALIAS", "BW_KEY_PASSWORD").filter { System.getenv(it).isNullOrEmpty() }
        if (releaseKeystore == null || missing.isNotEmpty()) {
            throw GradleException(
                "Release build refused: the release signing key is not configured (BW_KEYSTORE must point to the keystore file" +
                    (if (missing.isEmpty()) "" else " and ${missing.joinToString(", ")} must be set") +
                    "). Run tools/make-signing-key.sh once, then build with tools/build.sh apk. " +
                    "A release APK is never signed with the debug key: it could not update the installed app and would wipe the wallet.",
            )
        }
    }
}
