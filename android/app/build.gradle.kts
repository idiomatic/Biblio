import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

/// The app version; versionCode is major × 100 + minor, so 1.9 is 109.
val appVersion = "1.9"
/// ELF thread-local storage in the Zig core needs API 29; the native build targets the same level.
val minApi = 29
/// The NDK whose bionic the native library links; CI and DEVELOPMENT.md name the same version.
val ndkRelease = "29.0.14206865"

android {
    namespace = "com.rbrian.biblio"
    compileSdk = 36
    ndkVersion = ndkRelease

    defaultConfig {
        applicationId = "com.rbrian.biblio"
        minSdk = minApi
        targetSdk = 36
        versionCode = appVersion.split(".").let { it[0].toInt() * 100 + it[1].toInt() }
        versionName = appVersion
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
}

kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }

/// Builds libbiblio_jni.so (the Zig core plus its JNI glue) into src/main/jniLibs, with `zig` from
/// PATH or the `zig` Gradle property (`-Pzig=/path/to/zig`), linking the NDK's libc.
val buildCore by tasks.registering(Exec::class) {
    val zig = providers.gradleProperty("zig").getOrElse("zig")
    inputs.property("zig", zig)
    inputs.property("api", minApi)
    inputs.property("ndk", ndkRelease)
    inputs.files("../native/build.zig").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir("../native/src").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir("../../core/src").withPathSensitivity(PathSensitivity.RELATIVE)
    outputs.dir("src/main/jniLibs")
    workingDir = file("../native")
    val ndk = android.sdkDirectory.resolve("ndk/$ndkRelease")
    doFirst {
        if (!ndk.isDirectory) throw GradleException("Android NDK $ndkRelease not found in $ndk: sdkmanager \"ndk;$ndkRelease\"")
        commandLine(zig, "build", "-Drelease", "-Dapi=$minApi", "-Dndk=$ndk")
    }
}
tasks.named("preBuild") { dependsOn(buildCore) }

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material3:material3-adaptive-navigation-suite")
    implementation("androidx.compose.material3.adaptive:adaptive:1.0.0")
    implementation("androidx.compose.material3.adaptive:adaptive-layout:1.0.0")
    implementation("androidx.compose.material3.adaptive:adaptive-navigation:1.0.0")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("io.coil-kt.coil3:coil-compose:3.0.4")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.0.4")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
