package dev.gapul.tofupos

import android.test.AndroidTestCase

@Suppress("DEPRECATION")
class StoreTest : AndroidTestCase() {
  private val file = "tofu-test.sqlite"
  override fun setUp() { super.setUp(); context.deleteDatabase(file) }
  override fun tearDown() { context.deleteDatabase(file); super.tearDown() }
  fun testPersistenceIdempotencyAndCancellation() {
    val lines = listOf(Line("p1", "豆腐", 500, 2))
    POSStore(context, file).use { store ->
      store.saveProduct(Product("p1", "豆腐", 500))
      repeat(100) { assertEquals(1000L, store.checkout("same", lines, 2000).change) }
      store.saveProduct(Product("p1", "新豆腐", 700))
    }
    POSStore(context, file).use { store ->
      assertEquals(700L, store.products().single().price)
      assertEquals(500L, store.sales().single().lines.single().price)
      assertEquals(1, store.sales().size)
      store.cancel("same", "誤会計・返金済み")
      assertNotNull(store.sales().single().cancelledAt)
      try { store.cancel("same", "二度目"); fail("double cancel") } catch (_: IllegalArgumentException) { }
    }
  }
  fun testRollbackOnWriteFailure() {
    POSStore(context, file).use { store ->
      store.writableDatabase.execSQL("CREATE TRIGGER fail_second BEFORE INSERT ON order_lines WHEN NEW.line_no=2 BEGIN SELECT RAISE(ABORT,'injected write failure'); END")
      val lines = listOf(Line("p1", "豆腐", 500, 2), Line("p2", "別商品", 100, 1))
      try { store.checkout("rollback", lines, 2000); fail("write failure expected") } catch (_: android.database.sqlite.SQLiteException) { }
      assertTrue(store.sales().isEmpty())
      store.writableDatabase.execSQL("DROP TRIGGER fail_second")
      assertEquals(2, store.checkout("rollback", lines, 2000).lines.size)
    }
  }
  fun testOldReceiptDoesNotLoseCancellationAndGatePersists() {
    POSStore(context, file).use { store ->
      store.checkout("race", listOf(Line("p", "豆腐", 500, 1)), 1000)
      store.cancel("race", "返金済み")
      store.acknowledge(listOf(SyncReceipt("race", 1)))
      assertEquals(1, store.pendingCount()); assertEquals(2, store.pendingSales().single().revision)
      store.acknowledge(listOf(SyncReceipt("race", 2)))
      assertEquals(0, store.pendingCount())
      store.setSyncGate(1234567890.0, 3)
      store.bindSyncTarget("https://test.workers.dev/v1/sync")
      try { store.bindSyncTarget("https://other.workers.dev/v1/sync"); fail("target changed") } catch (_: IllegalArgumentException) { }
    }
    POSStore(context, file).use { assertEquals(1234567890.0, it.syncGate().first); assertEquals(3, it.syncGate().second) }
  }
  fun testVersionOneMigrationAndPendingLimit() {
    context.openOrCreateDatabase(file, 0, null).use { db ->
      db.execSQL("CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT NOT NULL,price INTEGER NOT NULL)")
      db.execSQL("CREATE TABLE orders(id TEXT PRIMARY KEY,created_at TEXT NOT NULL,total INTEGER NOT NULL,received INTEGER NOT NULL,change_yen INTEGER NOT NULL,cancelled_at TEXT,cancellation_reason TEXT)")
      db.execSQL("CREATE TABLE order_lines(order_id TEXT NOT NULL,line_no INTEGER NOT NULL,product_id TEXT NOT NULL,name TEXT NOT NULL,price INTEGER NOT NULL,quantity INTEGER NOT NULL,PRIMARY KEY(order_id,line_no))")
      db.execSQL("INSERT INTO orders VALUES('cancelled','2026-11-20T00:00:00Z',500,1000,500,'2026-11-20T00:01:00Z','返金済み')")
      db.execSQL("INSERT INTO order_lines VALUES('cancelled',1,'p','豆腐',500,1)")
      db.version = 1
    }
    POSStore(context, file).use { store ->
      assertEquals(2, store.pendingSales().single().revision)
      repeat(60) { store.checkout("o$it", listOf(Line("p", "豆腐", 500, 1)), 1000) }
      assertEquals(61, store.pendingCount()); assertEquals(50, store.pendingSales().size)
      store.holdSync(listOf("cancelled")); assertEquals(1, store.heldSyncCount())
      assertEquals(61, store.sales().size)
    }
  }
  fun testConcurrentSyncDoesNotQueueAnotherDatabaseRead() {
    val tasks = mutableListOf<Runnable>(); var secondRejected = false
    val sync = CloudSync(SyncCredentials(context), java.util.concurrent.Executor { tasks.add(it) }) { POSStore(context, file) }
    sync.run { }
    sync.run { secondRejected = it.isFailure }
    sync.backupProducts { assertTrue(it.isFailure) }
    sync.catalogs(null) { assertTrue(it.isFailure) }
    sync.restore(null,false) { assertTrue(it.isFailure) }
    assertEquals(1, tasks.size); assertTrue(sync.running.get()); assertTrue(secondRejected)
  }
  private fun backupSale(id: String = "o", price: Long = 500) = Sale(id,"2026-11-20T01:00:00Z",price,1000,1000-price,null,null,listOf(Line("p","豆腐",price,1)))
  fun testRestoreReplaysAndLocalCancellationNeverRollsBack() {
    POSStore(context,file).use { store ->
      val paid = backupSale()
      val page = RestorePage(listOf(Product("p","豆腐",500)),listOf(PendingSale(paid,1)),"","o",null)
      assertEquals(1,store.restore(page).orders);assertEquals(0,store.pendingCount())
      assertEquals(0,store.restore(page).orders);assertEquals(1,store.sales().size)
      store.cancel("o","端末で返金済み")
      store.restore(page)
      assertNotNull(store.sales().single().cancelledAt);assertEquals(1,store.pendingCount())
      val remote = paid.copy(cancelledAt="2026-11-20T01:01:00Z",cancellationReason="別の取消")
      assertEquals(1,store.restore(page.copy(orders=listOf(PendingSale(remote,2)))).conflicts)
      assertEquals("端末で返金済み",store.sales().single().cancellationReason);assertEquals(1,store.pendingCount())
      assertEquals(1,store.restore(RestorePage(emptyList(),emptyList(),"o",null,null)).conflicts)
    }
  }
  fun testRemoteCancellationAndChangedProductsKeepHistoricalPrices() {
    POSStore(context,file).use { store ->
      val paid=backupSale();val page=RestorePage(listOf(Product("p","豆腐",500)),listOf(PendingSale(paid,1)),"","o",null)
      store.restore(page);store.saveProduct(Product("p","新しい豆腐",700))
      val cancelled=paid.copy(cancelledAt="2026-11-20T01:01:00Z",cancellationReason="返金済み")
      val result=store.restore(page.copy(orders=listOf(PendingSale(cancelled,2))))
      assertEquals(1,result.cancellations);assertEquals(1,result.conflicts);assertEquals(0,store.pendingCount())
      store.restore(page)
      assertEquals(700L,store.products().single().price);assertEquals(500L,store.sales().single().lines.single().price)
      assertNotNull(store.sales().single().cancelledAt)
    }
  }
  fun testRestoreRollbackAndInvalidResponseCannotAdvanceCursor() {
    POSStore(context,file).use { store ->
      val page=RestorePage(listOf(Product("p","豆腐",500)),listOf(PendingSale(backupSale(),1)),"","o",null)
      store.writableDatabase.execSQL("CREATE TRIGGER fail_restore BEFORE INSERT ON order_lines BEGIN SELECT RAISE(ABORT,'restore failure'); END")
      try { store.restore(page);fail("expected write failure") } catch (_:android.database.sqlite.SQLiteException) { }
      assertTrue(store.products().isEmpty());assertTrue(store.sales().isEmpty());assertEquals("",store.restoreCursor().second)
      store.writableDatabase.execSQL("DROP TRIGGER fail_restore")
      try { store.restore(page.copy(next="wrong"));fail("bad cursor") } catch (_:IllegalArgumentException) { }
      assertTrue(store.products().isEmpty())
      store.restore(page)
    }
    POSStore(context,file).use { assertEquals("o",it.restoreCursor().second) }
  }
  fun testRestoreConflictingBaseAndFractionalMoneyAreRejected() {
    POSStore(context,file).use { store ->
      val first=RestorePage(emptyList(),listOf(PendingSale(backupSale(),1)),"","o",null)
      store.restore(first)
      assertEquals(1,store.restore(first.copy(orders=listOf(PendingSale(backupSale(price=600),1)))).conflicts)
      assertEquals(500L,store.sales().single().total)
      val json=org.json.JSONObject("""{"schema_version":1,"catalog_id":null,"after":"","next":"o","products":[{"id":"p","name":"p","price":0.5}],"orders":[]}""")
      try { RestorePage.parse(json,"",null);fail("fractional money") } catch (_:Exception) { }
    }
  }
  fun testRestoreTotalsSurviveTheEmptyCompletionPage() {
    POSStore(context,file).use { store ->
      store.restore(RestorePage(listOf(Product("p","豆腐",500)),listOf(PendingSale(backupSale(),1)),"","o",null))
      val total=store.restore(RestorePage(emptyList(),emptyList(),"o",null,null))
      assertEquals(1,total.products);assertEquals(1,total.orders);assertEquals("",store.restoreCursor().second)
    }
  }
}
