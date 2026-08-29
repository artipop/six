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
    `java-library`
}

repositories {
    maven { url = uri("https://maven-central.storage-download.googleapis.com/maven2/") }
    mavenCentral()
}

dependencies {
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
