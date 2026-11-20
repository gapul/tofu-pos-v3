package dev.gapul.tofupos

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/** Order of one sync cycle. Orders go first; images precede the products that reference them. */
enum class SyncStep { ORDERS, IMAGES, PRODUCTS, STOCK, SESSIONS, FEED, IMAGE_DOWNLOADS }

object ProductImages {
  const val MAX_SIDE = 800
  const val UPLOADS_PER_CYCLE = 5
  const val DOWNLOADS_PER_CYCLE = 10
  const val MAX_BYTES = 512 * 1024
  private val HASH = Regex("[0-9a-f]{64}")

  fun isHash(value: String?) = value != null && HASH.matches(value)
  /** Longest side at most [max], aspect kept, never upscaled, never below 1 px. */
  fun scaledSize(width: Int, height: Int, max: Int = MAX_SIDE): Pair<Int, Int> {
    require(width > 0 && height > 0)
    val longest = maxOf(width, height)
    if (longest <= max) return width to height
    return maxOf(1, Math.round(width.toDouble() * max / longest).toInt()) to maxOf(1, Math.round(height.toDouble() * max / longest).toInt())
  }
  /** Power-of-two decode subsampling that still leaves at least [max] px on the longest side. */
  fun sampleSize(width: Int, height: Int, max: Int = MAX_SIDE): Int {
    var sample = 1
    while (maxOf(width, height) / (sample * 2) >= max) sample *= 2
    return sample
  }
  fun sha256(bytes: ByteArray): String = buildString {
    MessageDigest.getInstance("SHA-256").digest(bytes).forEach { val v = it.toInt() and 0xff; append("0123456789abcdef"[v shr 4]); append("0123456789abcdef"[v and 0xf]) }
  }
  /** A product may be sent once its image exists in the cloud (uploaded or downloaded from it). */
  fun sendable(imageHash: String?, uploaded: Set<String>) = imageHash == null || imageHash in uploaded

  fun directory(context: Context) = File(context.filesDir, ((context.applicationContext as? POSApplication)?.currentEnvironment ?: AppEnvironment.PRODUCTION).imageFolder)
  fun file(directory: File, hash: String) = File(directory, "$hash.jpg")

  /**
   * Decodes the picked image with its EXIF orientation applied, shrinks it to 800 px and re-encodes JPEG 80.
   * The re-encoded file carries no EXIF, so location and camera data never leave the device.
   */
  @SuppressLint("UseKtx") // core-ktx is not a dependency
  fun import(context: Context, uri: Uri): Pair<String, ByteArray> {
    val bitmap = decode(context, uri)
    val (w, h) = scaledSize(bitmap.width, bitmap.height)
    // JPEG has no alpha: flatten onto white.
    val flat = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    Canvas(flat).apply { drawColor(Color.WHITE); drawBitmap(Bitmap.createScaledBitmap(bitmap, w, h, true), 0f, 0f, null) }
    var bytes = ByteArray(0)
    for (quality in listOf(80, 70, 60, 50)) {
      bytes = ByteArrayOutputStream().also { flat.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()
      if (bytes.size <= MAX_BYTES) break
    }
    require(bytes.size in 1..MAX_BYTES) { "写真が大きすぎます" }
    return sha256(bytes) to bytes
  }
  /** Writes atomically, so a crash never leaves a truncated file under its hash. */
  fun save(directory: File, hash: String, bytes: ByteArray) {
    require(isHash(hash) && sha256(bytes) == hash) { "写真の内容が一致しません" }
    directory.mkdirs()
    val target = file(directory, hash); if (target.length() == bytes.size.toLong()) return
    val temp = File(directory, "$hash.tmp")
    temp.outputStream().use { it.write(bytes); it.fd.sync() }
    check(temp.renameTo(target)) { "写真を保存できません" }
  }
  // The framework ExifInterface only runs on API 26-27 (ImageDecoder handles 28+); no androidx dependency is added.
  @SuppressLint("ExifInterface")
  private fun decode(context: Context, uri: Uri): Bitmap {
    if (Build.VERSION.SDK_INT >= 28) {
      // ImageDecoder applies the EXIF orientation itself.
      return ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
        val (w, h) = scaledSize(info.size.width, info.size.height)
        decoder.setTargetSize(w, h); decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
      }
    }
    val resolver = context.contentResolver
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) } ?: error("写真を開けません")
    require(bounds.outWidth > 0 && bounds.outHeight > 0) { "写真を読み込めません" }
    val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight) }
    val bitmap = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: error("写真を読み込めません")
    val orientation = runCatching { resolver.openInputStream(uri)?.use { android.media.ExifInterface(it).getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL) } }.getOrNull()
    val matrix = Matrix().apply {
      when (orientation) {
        android.media.ExifInterface.ORIENTATION_ROTATE_90 -> postRotate(90f)
        android.media.ExifInterface.ORIENTATION_ROTATE_180 -> postRotate(180f)
        android.media.ExifInterface.ORIENTATION_ROTATE_270 -> postRotate(270f)
        android.media.ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
        android.media.ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
        android.media.ExifInterface.ORIENTATION_TRANSPOSE -> { postRotate(90f); postScale(-1f, 1f) }
        android.media.ExifInterface.ORIENTATION_TRANSVERSE -> { postRotate(270f); postScale(-1f, 1f) }
      }
    }
    return if (matrix.isIdentity) bitmap else Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
  }
  /** Thumbnail decode for display; null when the file is missing or unreadable. */
  fun thumbnail(directory: File, hash: String, maxSide: Int): Bitmap? {
    val target = file(directory, hash); if (!target.isFile) return null
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(target.path, bounds)
    if (bounds.outWidth <= 0) return null
    return BitmapFactory.decodeFile(target.path, BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxSide) })
  }
  /** Run at process start: drops image files and rows no product references any more. */
  fun cleanup(directory: File, store: POSStore) {
    val used = store.referencedImages()
    store.forgetImages(used)
    directory.listFiles()?.forEach { f -> if (f.name.removeSuffix(".jpg").removeSuffix(".tmp") !in used || f.name.endsWith(".tmp")) f.delete() }
  }
}
