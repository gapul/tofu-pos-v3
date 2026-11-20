plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
  id("org.jetbrains.kotlin.plugin.compose")
}
android {
  namespace = "dev.gapul.tofupos"
  compileSdk = 36
  defaultConfig {
    applicationId = "dev.gapul.tofupos.v3"
    minSdk = 26
    targetSdk = 35
    versionCode = 7
    versionName = "0.4.0"
    testInstrumentationRunner = "android.test.InstrumentationTestRunner"
    // The legacy runner otherwise scans every Compose dependency for JUnit 3 tests.
    testInstrumentationRunnerArguments["class"] = "dev.gapul.tofupos.StoreTest"
    manifestPlaceholders["appLabel"] = "TOS"
  }
  buildTypes {
    // Side-by-side app for sync tests on a phone that holds real sales. Separate package, data and label.
    create("synctest") {
      initWith(getByName("debug"))
      applicationIdSuffix = ".synctest"
      versionNameSuffix = "-synctest"
      manifestPlaceholders["appLabel"] = "TOS 検証"
      matchingFallbacks += "debug"
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions { jvmTarget = "17" }
  buildFeatures { compose = true }
  useLibrary("android.test.runner")
  useLibrary("android.test.base")
  useLibrary("android.test.mock")
}
dependencies {
  implementation("androidx.activity:activity-compose:1.10.1")
  // Expressive APIs with our current AGP/SDK; stable 1.5 requires AGP 9.1 + SDK 37.
  implementation("androidx.compose.material3:material3:1.5.0-alpha18")
  implementation("androidx.compose.material:material-icons-core:1.7.8")
  testImplementation("junit:junit:4.13.2")
  // android.jar only stubs org.json; JVM tests of the cloud JSON parsers need the real one.
  testImplementation("org.json:json:20240303")
}

// Connected tests install/uninstall the app. Never select every attached phone.
tasks.matching { it.name.startsWith("connected") && it.name.endsWith("AndroidTest") }.configureEach {
  doFirst {
    val serial = System.getenv("ANDROID_SERIAL").orEmpty()
    require(serial.isNotEmpty() && !serial.contains(",")) { "Set ANDROID_SERIAL to one dedicated test emulator" }
    require(serial.startsWith("emulator-") || System.getenv("TOFU_ALLOW_PHYSICAL_TESTS") == "true") {
      "Physical-device tests require explicit user authorization and TOFU_ALLOW_PHYSICAL_TESTS=true"
    }
  }
}
