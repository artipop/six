// AGP 9 applies Kotlin itself — `org.jetbrains.kotlin.android` is refused outright now, and the
// Kotlin DSL below is AGP's own rather than the Kotlin plugin's.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "org.deffun.six"
    compileSdk = 37

    defaultConfig {
        applicationId = "org.deffun.six"
        // 34 is where androidx.webkit's multi-profile API arrives, and profiles are not an optional
        // part of six — a build that cannot keep two profiles apart is a different app.
        minSdk = 34
        targetSdk = 37
        versionCode = 1
        versionName = "0.1"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.webkit)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
}
