plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

val requestedAbi = System.getenv("MISAKA_ANDROID_ABI")
require(requestedAbi == null || requestedAbi in listOf("arm64-v8a", "x86_64"))
val releaseKeystore = System.getenv("MISAKA_ANDROID_KEYSTORE")
val allowDebugSigning = System.getenv("MISAKA_ANDROID_ALLOW_DEBUG_SIGNING") == "1"

android {
    namespace = "com.misakanetwork.last_order"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.misakanetwork.last_order"
        minSdk = 36
        targetSdk = 36
        versionCode = flutter.versionCode + when (requestedAbi) {
            "arm64-v8a" -> 2000
            "x86_64" -> 4000
            else -> 0
        }
        versionName = flutter.versionName
        ndk { abiFilters += if (requestedAbi == null) listOf("arm64-v8a", "x86_64") else listOf(requestedAbi) }
    }
    buildFeatures { buildConfig = true }
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = requireNotNull(System.getenv("MISAKA_ANDROID_STORE_PASSWORD"))
                keyAlias = requireNotNull(System.getenv("MISAKA_ANDROID_KEY_ALIAS"))
                keyPassword = requireNotNull(System.getenv("MISAKA_ANDROID_KEY_PASSWORD"))
            }
        }
    }
    buildTypes {
        release {
            signingConfig = when {
                releaseKeystore != null -> signingConfigs.getByName("release")
                allowDebugSigning -> signingConfigs.getByName("debug")
                else -> null
            }
            // JNI's symbol name is part of the method-channel ABI.
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    packaging {
        jniLibs { useLegacyPackaging = false }
        resources { excludes += listOf("META-INF/DEPENDENCIES") }
    }
    androidResources { noCompress += "bundle" }
}

chaquopy {
    defaultConfig {
        version = "3.11"
        System.getenv("MISAKA_ANDROID_BUILD_PYTHON")?.let { buildPython(it) }
        pip {
            // Avoid a host-native charset-normalizer wheel; every client
            // dependency has a portable wheel available.
            options("--only-binary=:all:")
            install("-r", "src/main/python/requirements-android.lock")
        }
    }
}

kotlin {
    compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 }
}

flutter { source = "../.." }
