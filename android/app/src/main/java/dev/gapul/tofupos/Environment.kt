package dev.gapul.tofupos

/**
 * Production and test keep fully separate data: database, photos, saved connection, bundled default connection, and
 * (inside each database) sync target, backoff and feed cursor. Production keeps the 0.3.0 names, so existing data stays.
 */
enum class AppEnvironment(val key: String) {
  PRODUCTION("production"), TEST("test");
  private val suffix get() = if (this == PRODUCTION) "" else "-test"
  val database get() = "tofu-pos$suffix.sqlite"
  val imageFolder get() = "product-images$suffix"
  val connectionKey get() = "connection$suffix"
  val keyAlias get() = if (this == PRODUCTION) "dev.gapul.tofupos.sync" else "dev.gapul.tofupos.sync.test"
  val bundledConnection get() = "sync-default$suffix.json"
  val label get() = if (this == PRODUCTION) "本番" else "テスト"
  companion object {
    const val PREFERENCES = "environment"
    const val PREFERENCE_KEY = "current"
    fun parse(value: String?) = entries.firstOrNull { it.key == value } ?: PRODUCTION
  }
}
