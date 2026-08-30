/*
 * `:core` is a plain JVM module on purpose — no Android plugin, no Compose, nothing from the SDK.
 *
 * It holds the pieces that have to agree with the Mac exactly: the strip's geometry first, the
 * snapshot and the schema after. Keeping Android off its classpath is what lets `./gradlew
 * :core:test` run the whole contract with no device, no emulator and no SDK in the way — and what
 * stops a UI concern from quietly leaking into a model four front ends share.
 *
 * `:app` depends on this. It never depends on `:app`.
 */

import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    `java-library`
}

// No `repositories` block: the build's own, in settings.gradle.kts, is the only list. `:core` used
// to resolve from Maven Central alone, which stopped being true the moment it took androidx.sqlite.

dependencies {
    api(libs.kotlinx.serialization.json)
    // The bundled driver compiles its own SQLite rather than using the platform's, which is what
    // makes "the same schema" true across devices instead of approximately true — and is the only
    // build that would ever take sqlite-vec through `addExtension`. It is also a KMP artifact with a
    // JVM target, which is why the whole storage layer stays testable in `:core` without a device.
    api(libs.androidx.sqlite)
    api(libs.androidx.sqlite.bundled)

    testImplementation(libs.kotlin.test)
    testImplementation(libs.junit.jupiter.engine)
    testRuntimeOnly(libs.junit.platform.launcher)
}

// No toolchain block. The only JDK on this machine is Android Studio's JBR, and asking Gradle for
// another sends it to foojay, which cannot reach GitHub's release assets from here. Kotlin runs on
// whatever JDK Gradle is on and emits 17 either way — which is what `:app` will want.
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

tasks.named<Test>("test") {
    useJUnitPlatform()
    testLogging { events("passed", "failed", "skipped") }
}
