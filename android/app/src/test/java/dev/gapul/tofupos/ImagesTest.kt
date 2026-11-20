package dev.gapul.tofupos

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ImagesTest {
  @Test fun scaledSizeKeepsAspectAndNeverUpscales() {
    assertEquals(800 to 600, ProductImages.scaledSize(4000, 3000))
    assertEquals(600 to 800, ProductImages.scaledSize(3000, 4000))
    assertEquals(800 to 800, ProductImages.scaledSize(1200, 1200))
    assertEquals(640 to 480, ProductImages.scaledSize(640, 480))
    assertEquals(800 to 1, ProductImages.scaledSize(10000, 3))
    assertEquals(800 to 450, ProductImages.scaledSize(1920, 1080))
    assertThrows(IllegalArgumentException::class.java) { ProductImages.scaledSize(0, 10) }
  }
  @Test fun sampleSizeLeavesEnoughPixels() {
    assertEquals(1, ProductImages.sampleSize(1200, 900))
    assertEquals(2, ProductImages.sampleSize(1600, 1200))
    assertEquals(4, ProductImages.sampleSize(4032, 3024))
    assertTrue(4032 / ProductImages.sampleSize(4032, 3024) >= 800)
    assertEquals(1, ProductImages.sampleSize(300, 300))
  }
  @Test fun sha256IsLowercaseHex() {
    assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", ProductImages.sha256(ByteArray(0)))
    assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", ProductImages.sha256("abc".toByteArray()))
    assertTrue(ProductImages.isHash(ProductImages.sha256(byteArrayOf(1, 2, 3))))
    assertFalse(ProductImages.isHash("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
    assertFalse(ProductImages.isHash("abc")); assertFalse(ProductImages.isHash(null))
  }
  @Test fun productsWaitForTheirImage() {
    val hash = ProductImages.sha256("x".toByteArray())
    assertTrue(ProductImages.sendable(null, emptySet()))
    assertFalse(ProductImages.sendable(hash, emptySet()))
    assertTrue(ProductImages.sendable(hash, setOf(hash)))
  }
  @Test fun cycleOrder() {
    assertEquals(listOf(SyncStep.ORDERS, SyncStep.IMAGES, SyncStep.PRODUCTS, SyncStep.STOCK, SyncStep.SESSIONS, SyncStep.FEED, SyncStep.IMAGE_DOWNLOADS), SyncStep.entries.toList())
  }
  @Test fun cloudProductImageHash() {
    val hash = ProductImages.sha256("photo".toByteArray())
    val base = """{"id":"p","name":"田楽豆腐","price":500,"active":true,"track_stock":true,"version":1,"stock":3"""
    assertEquals(hash, CloudJSON.product(JSONObject("$base,\"image_hash\":\"$hash\"}")).imageHash)
    assertNull(CloudJSON.product(JSONObject("$base,\"image_hash\":null}")).imageHash)
    assertNull(CloudJSON.product(JSONObject("$base}")).imageHash)
    assertThrows(IllegalArgumentException::class.java) { CloudJSON.product(JSONObject("$base,\"image_hash\":\"../etc\"}")) }
    val local = Product("p", "田楽豆腐", 500, imageHash = hash)
    assertFalse(local.sameContent(local.copy(imageHash = null)))
  }
}
