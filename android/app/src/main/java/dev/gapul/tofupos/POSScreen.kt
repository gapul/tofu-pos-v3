@file:OptIn(androidx.compose.material3.ExperimentalMaterial3ExpressiveApi::class)
package dev.gapul.tofupos

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.pager.HorizontalPager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// 2026 "Are you Tofu?" palette: paper white, sesame/char text, miso amber, tofu-top yellow. Error colors stay default.
private val light = expressiveLightColorScheme().copy(
  primary = Color(0xFFB66427), onPrimary = Color.White,
  primaryContainer = Color(0xFFF3DCC6), onPrimaryContainer = Color(0xFF503225),
  secondary = Color(0xFF503225), onSecondary = Color.White,
  secondaryContainer = Color(0xFFF3DCC6), onSecondaryContainer = Color(0xFF503225),
  tertiary = Color(0xFF635954), onTertiary = Color.White,
  tertiaryContainer = Color(0xFFFFE8A9), onTertiaryContainer = Color(0xFF2E2018),
  background = Color(0xFFF8F7F6), onBackground = Color(0xFF2E2018),
  surface = Color(0xFFF8F7F6), onSurface = Color(0xFF2E2018), onSurfaceVariant = Color(0xFF635954),
  surfaceContainerLowest = Color.White, surfaceContainerLow = Color.White, surfaceContainer = Color.White,
  surfaceContainerHigh = Color.White, surfaceContainerHighest = Color.White,
  outline = Color(0xFF635954), outlineVariant = Color(0xFFD9D2CD)
)
private val dark = darkColorScheme(
  primary = Color(0xFFD18C53), onPrimary = Color(0xFF2E2018),
  primaryContainer = Color(0xFF503225), onPrimaryContainer = Color(0xFFF3DCC6),
  secondary = Color(0xFFCB8D59), onSecondary = Color(0xFF2E2018),
  secondaryContainer = Color(0xFF503225), onSecondaryContainer = Color(0xFFF3DCC6),
  tertiary = Color(0xFFADA29C), onTertiary = Color(0xFF2E2018),
  tertiaryContainer = Color(0xFFFFE8A9), onTertiaryContainer = Color(0xFF2E2018),
  background = Color(0xFF2E2018), onBackground = Color(0xFFF6F4F3),
  surface = Color(0xFF2E2018), onSurface = Color(0xFFF6F4F3), onSurfaceVariant = Color(0xFFADA29C),
  surfaceContainerLowest = Color(0xFF3B2A20), surfaceContainerLow = Color(0xFF3B2A20), surfaceContainer = Color(0xFF3B2A20),
  surfaceContainerHigh = Color(0xFF3B2A20), surfaceContainerHighest = Color(0xFF3B2A20),
  outline = Color(0xFFADA29C), outlineVariant = Color(0xFF635954)
)
@Composable fun TofuTheme(content: @Composable () -> Unit) {
  MaterialExpressiveTheme(colorScheme = if (isSystemInDarkTheme()) dark else light, content = content)
}
/** Loading mark: the tofu bounces (scaleY 1.0 <-> 0.85, 0.8 s cycle); static when system animations are off. */
@Composable fun TofuLoading(modifier: Modifier = Modifier, size: androidx.compose.ui.unit.Dp = 64.dp) {
  val context = LocalContext.current
  val still = remember { android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
  val scale = if (still) 1f else rememberInfiniteTransition(label = "tofu").animateFloat(1f, 0.85f,
    infiniteRepeatable(tween(400, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "bounce").value
  Box(modifier.size(size).clip(CircleShape).background(MaterialTheme.colorScheme.primaryContainer).semantics { contentDescription = "読み込み中" }, contentAlignment = Alignment.Center) {
    Image(painterResource(R.drawable.ic_tofu_foreground), null, Modifier.fillMaxSize().graphicsLayer { scaleY = scale; transformOrigin = TransformOrigin(0.5f, 0.82f) })
  }
}
internal fun yen(amount: Long) = "¥${NumberFormat.getIntegerInstance(Locale.JAPAN).format(amount)}"
private fun jst(value: String): String = runCatching {
  DateTimeFormatter.ofPattern("yyyy/M/d HH:mm:ss 'JST'").withZone(ZoneId.of("Asia/Tokyo")).format(Instant.parse(value))
}.getOrDefault(value)
@Composable private fun Action(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
  Button(onClick, shapes = ButtonDefaults.shapes(), modifier = modifier.heightIn(min = 56.dp), enabled = enabled) {
    Text(label, style = MaterialTheme.typography.titleMedium)
  }
}
@Composable private fun Info(title: String, body: String) {
  Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
    Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
      Text(title, style = MaterialTheme.typography.titleMedium)
      Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
  }
}
/** Values added in 0.4.0, grouped so the screen signature stays readable. */
data class ScreenExtras(
  val stocks: Map<String, Long?> = emptyMap(), val age: String? = null, val gender: String? = null,
  val drawer: DrawerSession? = null, val summary: SessionSummary? = null, val lastFeedAt: String? = null, val deviceLabel: String = "",
  val held: Held = Held(), val deviceID: String = "", val lastSentAt: String? = null, val syncFailed: Boolean = false, val imageGeneration: Int = 0,
  val environment: AppEnvironment = AppEnvironment.PRODUCTION,
  val group: String? = null, val customerEpoch: Int = 0, val ticketPrefix: String = ""
) { val test get() = environment == AppEnvironment.TEST }
/** Items left out of automatic sync: refused by the cloud (HTTP 400) and conflicting orders. */
data class Held(val products: Int = 0, val stock: Int = 0, val sessions: Int = 0, val conflicts: Int = 0, val images: Int = 0) {
  val any get() = products + stock + sessions + conflicts + images > 0
}
@Composable fun POSScreen(
  products: List<Product>, sales: List<Sale>, cart: List<Line>, cash: String, tab: Int,
  ready: Boolean, busy: Boolean, pending: Int, syncing: Boolean, syncMessage: String, extras: ScreenExtras,
  onTab: (Int) -> Unit, onCash: (String) -> Unit, onQuantity: (String, Int) -> Unit,
  onExact: () -> Unit, onCashSet: (Long) -> Unit, onCashAdd: (Long) -> Unit, onAge: (String) -> Unit, onGender: (String) -> Unit,
  onCheckout: () -> Unit, onEdit: (Product?) -> Unit, onStock: (Product, String) -> Unit,
  onOpenDrawer: (Map<String, Int>) -> Unit, onCloseDrawer: (Map<String, Int>) -> Unit,
  onCancel: (Sale) -> Unit, onExport: () -> Unit, onSync: () -> Unit,
  onSettings: () -> Unit, onImport: () -> Unit, canContinue: Boolean,
  onBackup: () -> Unit, onRestore: () -> Unit, onContinue: () -> Unit,
  advanced: Boolean, onAdvanced: (Boolean) -> Unit,
  single: SingleState, onSingle: (SingleState) -> Unit, onSingleConfirm: () -> Unit, snackbar: SnackbarHostState,
  onEnvironment: (AppEnvironment) -> Unit, onGroup: (String) -> Unit, onTicketPrefix: (String) -> Unit
) {
  val focus = LocalFocusManager.current
  val enabled = ready && !busy
  var sheet by rememberSaveable { mutableStateOf(false) }
  if (advanced) {
    BackHandler { onAdvanced(false) }
    Advanced(extras, enabled && !syncing, canContinue, { onAdvanced(false) }, onSettings, onImport, onBackup, onRestore, onContinue, onEnvironment, onTicketPrefix)
    return
  }
  val labels = listOf("レジ", "商品", "履歴", "締め")
  val icons = listOf(Icons.Default.ShoppingCart, Icons.Default.Add, Icons.AutoMirrored.Filled.List, Icons.Default.Lock)
  val keyboardVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0
  // Lifted above the single-product "購入" button so the next sale is never blocked by the notice.
  Scaffold(snackbarHost = { SnackbarHost(snackbar, Modifier.padding(bottom = 88.dp)) { data ->
    Snackbar(action = { data.visuals.actionLabel?.let { label -> TextButton(data::performAction) { Text(label) } } }) {
      Column {
        data.visuals.message.lines().filter { it.isNotBlank() }.forEach { line ->
          if (line.startsWith("整理番号")) Text(line, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.ExtraBold)
          else Text(line, fontWeight = if (line.startsWith("【テスト】")) FontWeight.Bold else null)
        }
      }
    }
  } }, bottomBar = {
    if (!keyboardVisible) NavigationBar { labels.forEachIndexed { index, title ->
      NavigationBarItem(selected = tab == index, onClick = { focus.clearFocus(); onTab(index) },
        icon = { Icon(icons[index], null) }, label = { Text(title) })
    } }
  }) { insets ->
    BoxWithConstraints(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets).imePadding()) {
      val compact = maxHeight < 520.dp || LocalDensity.current.fontScale > 1.4f
      Column(Modifier.fillMaxSize()) {
        // The bar stays on small/landscape screens; only the title shrinks so the icons remain reachable.
        // Test environment: the bar turns errorContainer and carries a badge so test sales are never mistaken for real ones.
        Row(Modifier.fillMaxWidth().background(if (extras.test) MaterialTheme.colorScheme.errorContainer else Color.Transparent)
          .padding(start = 24.dp, end = 8.dp, top = if (compact) 4.dp else 12.dp, bottom = if (compact) 0.dp else 8.dp), verticalAlignment = Alignment.CenterVertically) {
          Text(labels[tab.coerceIn(0, 3)], Modifier.weight(1f, fill = false), style = if (compact) MaterialTheme.typography.titleLarge else MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            color = if (extras.test) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurface)
          if (extras.test) TestBadge(Modifier.padding(start = 10.dp))
          Spacer(Modifier.weight(1f))
          if (tab == 2) IconButton(onExport, enabled = enabled && sales.isNotEmpty(), modifier = Modifier.size(48.dp)) {
            Icon(painterResource(R.drawable.ic_download), "CSVに書き出す")
          }
          SyncButton(pending, syncing, extras) { focus.clearFocus(); sheet = true }
        }
        if (!ready) Column(Modifier.fillMaxSize().padding(24.dp), Arrangement.spacedBy(16.dp, Alignment.CenterVertically), Alignment.CenterHorizontally) {
          if (busy) TofuLoading()
          Text(if (busy) "保存データを読み込んでいます…" else "保存データを開けません。アプリを削除せず確認してください。")
        } else when (tab) {
          // Exactly one product on sale switches the register to the single-product screen.
          0 -> products.filter { it.active }.let { onSale ->
            if (onSale.size == 1) SingleRegister(onSale.single(), extras.stocks[onSale.single().id], single, extras, enabled, onSingle, onAge, onGender, onGroup, onSingleConfirm)
            else Register(onSale, cart, cash, extras, enabled, compact, onCash, onQuantity, onExact, onCashSet, onCashAdd, onAge, onGender, onGroup, onCheckout)
          }
          1 -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Action("商品を追加", { onEdit(null) }, Modifier.fillMaxWidth(), enabled) }
            if (products.isEmpty()) item { Info("商品を登録しましょう", "商品名と価格を登録すると、レジから選べるようになります。") }
            items(products, key = { it.id }) { p ->
              Card(onClick = { onEdit(p) }, enabled = enabled, shape = RoundedCornerShape(24.dp)) {
                Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    ProductPhoto(p.imageHash, extras.imageGeneration, 64.dp, 16.dp)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                      Text(p.name, style = MaterialTheme.typography.titleMedium)
                      Text(yen(p.price), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                      val status = listOfNotNull(if (p.active) "販売中" else "停止中", if (p.stopAtZero) "在庫0で販売停止" else null, if (p.dirty) "未送信" else null)
                      Text(status.joinToString(" · "), style = MaterialTheme.typography.labelLarge,
                        color = if (p.active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
                      val stock = extras.stocks[p.id]
                      Text(stock?.let { "在庫 ${count(it)}" } ?: "在庫 未取得", style = MaterialTheme.typography.titleMedium,
                        color = if (stock != null && stock <= 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                    }
                    Icon(Icons.Default.Edit, "${p.name}を編集")
                  }
                  Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton({ onStock(p, "set") }, Modifier.weight(1f).heightIn(min = 48.dp), enabled = enabled) { Text("在庫を数えて設定") }
                    OutlinedButton({ onStock(p, "add") }, Modifier.weight(1f).heightIn(min = 48.dp), enabled = enabled) { Text("入荷を追加") }
                  }
                }
              }
            }
          }
          2 -> History(sales, enabled, onCancel)
          else -> Closing(extras.drawer, extras.summary, enabled, onOpenDrawer, onCloseDrawer)
        }
      }
    }
  }
  if (sheet) SyncSheet(pending, syncing, syncMessage, extras, enabled, { sheet = false }, onSync) { sheet = false; onAdvanced(true) }
}
@Composable private fun SyncButton(pending: Int, syncing: Boolean, extras: ScreenExtras, open: () -> Unit) {
  val warn = extras.syncFailed || extras.held.any
  val label = when { syncing -> "同期中"; warn -> "同期に問題があります"; pending > 0 -> "未同期${pending}件"; else -> "同期済み" }
  IconButton(open, Modifier.size(48.dp).semantics { contentDescription = label }) {
    BadgedBox(badge = { if (pending > 0) Badge { Text(if (pending > 99) "99+" else "$pending") } else if (warn) Badge() }) {
      Icon(painterResource(if (warn) R.drawable.ic_cloud_off else if (pending == 0 && !syncing) R.drawable.ic_cloud_done else R.drawable.ic_cloud), null,
        tint = if (warn) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
    }
  }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun SyncSheet(pending: Int, syncing: Boolean, message: String, extras: ScreenExtras, enabled: Boolean,
  dismiss: () -> Unit, send: () -> Unit, advanced: () -> Unit) {
  ModalBottomSheet(onDismissRequest = dismiss) {
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
      if (extras.test) TestBadge()
      Text("未同期の会計", style = MaterialTheme.typography.titleMedium)
      Text("${pending}件", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
      Text("会計は端末に保存し、自動でクラウドへ送信します。他の端末の売上・商品・在庫は表示中に1分ごとに取り込みます。", style = MaterialTheme.typography.bodyMedium)
      if (syncing) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { TofuLoading(size = 40.dp); Text("送信しています…") }
      else if (message.isNotBlank()) Text(message, color = if (extras.syncFailed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
      Text("最終送信: ${extras.lastSentAt?.let(::jst) ?: "まだありません"}\n最終取り込み: ${extras.lastFeedAt?.let(::jst) ?: "まだありません"}", style = MaterialTheme.typography.bodyMedium)
      val held = extras.held
      listOf("商品" to held.products, "写真" to held.images, "在庫" to held.stock, "レジ記録" to held.sessions).filter { it.second > 0 }.takeIf { it.isNotEmpty() }?.let { rows ->
        Text("送信できなかった" + rows.joinToString("・") { "${it.first} ${it.second}件" } + "（端末に保持しています）", color = MaterialTheme.colorScheme.error)
      }
      if (held.conflicts > 0) Text("競合で保留中の会計 ${held.conflicts}件。自動では送信しません。「今すぐ送信」で1回再送します。", color = MaterialTheme.colorScheme.error)
      Action("今すぐ送信", send, Modifier.fillMaxWidth(), enabled && !syncing)
      TextButton(advanced, Modifier.align(Alignment.End)) { Text("詳細設定", style = MaterialTheme.typography.labelMedium) }
    }
  }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun TestBadge(modifier: Modifier = Modifier) {
  Surface(modifier, color = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError, shape = RoundedCornerShape(8.dp)) {
    Text("テスト", Modifier.padding(horizontal = 10.dp, vertical = 4.dp), style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, maxLines = 1)
  }
}
@Composable private fun Advanced(extras: ScreenExtras, enabled: Boolean, canContinue: Boolean, back: () -> Unit,
  onSettings: () -> Unit, onImport: () -> Unit, onBackup: () -> Unit, onRestore: () -> Unit, onContinue: () -> Unit,
  onEnvironment: (AppEnvironment) -> Unit, onTicketPrefix: (String) -> Unit) {
  var confirm by rememberSaveable { mutableStateOf(false) }
  var prefix by rememberSaveable(extras.ticketPrefix) { mutableStateOf(extras.ticketPrefix) }
  val target = if (extras.test) AppEnvironment.PRODUCTION else AppEnvironment.TEST
  if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text(if (extras.test) "本番環境に戻します" else "テスト環境に切り替えます") },
    text = { Text((if (extras.test) "本番の売上・商品・接続に戻ります。" else "テストの売上は本番に入りません。") + "カートなど今の画面の入力は破棄されます。") },
    confirmButton = { TextButton({ confirm = false; onEnvironment(target) }, enabled = enabled) { Text("切り替える") } },
    dismissButton = { TextButton({ confirm = false }) { Text("戻る") } })
  Scaffold(topBar = { TopAppBar(title = { Text("詳細設定") }, navigationIcon = { IconButton(back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "戻る") } }) }) { insets ->
    LazyColumn(Modifier.fillMaxSize().padding(insets), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
      item { Info("通常は操作不要です", "同期は自動で行います。接続先の変更や復元が必要なときだけ使ってください。") }
      item { OutlinedButton(onSettings, Modifier.fillMaxWidth().heightIn(min = 56.dp), enabled = enabled) { Text("接続設定（URL・トークン）") } }
      item { OutlinedButton(onImport, Modifier.fillMaxWidth().heightIn(min = 56.dp), enabled = enabled) { Text("同期設定ファイルを読み込む") } }
      item { OutlinedButton(onBackup, Modifier.fillMaxWidth().heightIn(min = 56.dp), enabled = enabled) { Text("商品をバックアップ") } }
      item { OutlinedButton(onRestore, Modifier.fillMaxWidth().heightIn(min = 56.dp), enabled = enabled) { Text("クラウドから復元") } }
      if (canContinue) item { Action("売上の続きを復元", onContinue, Modifier.fillMaxWidth(), enabled) }
      item { Text("復元は最大50会計ずつ取り込み、端末の内容が異なる場合は保持します。", style = MaterialTheme.typography.bodySmall) }
      item { Info("この端末", "端末名: ${extras.deviceLabel}\n端末ID: ${extras.deviceID}") }
      item { Card(shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
          Text("整理番号の接頭辞", style = MaterialTheme.typography.titleMedium)
          Text("端末ごとに英大文字1〜2文字（例: A → 「A-12」）。空欄なら番号だけ。番号は毎日1から始まります。", style = MaterialTheme.typography.bodySmall)
          val clean = prefix.trim().uppercase(Locale.ROOT)
          Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(prefix, { prefix = it.take(2) }, Modifier.weight(1f), singleLine = true, enabled = enabled, label = { Text("接頭辞") },
              isError = !Tickets.validPrefix(clean), keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters))
            Button({ onTicketPrefix(clean) }, enabled = enabled && Tickets.validPrefix(clean) && clean != extras.ticketPrefix) { Text("保存") }
          }
        }
      } }
      item { Card(shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
          Row(verticalAlignment = Alignment.CenterVertically) {
            Text("環境: ${extras.environment.label}", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            if (extras.test) TestBadge()
          }
          Text("本番とテストは端末のデータ・写真・接続先が完全に分かれています。同期中は切り替えできません。", style = MaterialTheme.typography.bodySmall)
          OutlinedButton({ confirm = true }, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = enabled) { Text(if (extras.test) "本番環境に戻す" else "テスト環境に切り替える") }
        }
      } }
    }
  }
}
/** After each saved sale the register returns to the top (product card, quantity). Jumps when animations are off. */
@Composable private fun ScrollToTopAfterSale(epoch: Int, list: androidx.compose.foundation.lazy.LazyListState, still: Boolean) {
  var seen by rememberSaveable { mutableIntStateOf(epoch) }
  LaunchedEffect(epoch) {
    if (epoch == seen) return@LaunchedEffect
    seen = epoch
    if (still) list.scrollToItem(0) else list.animateScrollToItem(0)
  }
}
/** True when system animations are off; scrolling then jumps instead of animating. */
@Composable private fun reducedMotion(): Boolean {
  val context = LocalContext.current
  return remember { android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
}
/**
 * Customer segment as three swipeable pages (年齢 → 性別 → 集団). Choosing a chip moves to the next page; after 集団
 * [onDone] scrolls the register. Tapping the chosen chip only clears it. Every axis is optional.
 */
@Composable private fun CustomerPager(extras: ScreenExtras, enabled: Boolean, onAge: (String) -> Unit, onGender: (String) -> Unit, onGroup: (String) -> Unit, onDone: () -> Unit) {
  val pager = rememberPagerState { 3 }
  val scope = rememberCoroutineScope(); val still = reducedMotion()
  fun go(page: Int) { scope.launch { if (still) pager.scrollToPage(page) else pager.animateScrollToPage(page) } }
  LaunchedEffect(extras.customerEpoch) { if (pager.currentPage != 0) pager.scrollToPage(0) }
  val axes = listOf(Triple("年齢", Customer.AGES, extras.age), Triple("性別", Customer.GENDERS, extras.gender), Triple("集団", Customer.GROUPS, extras.group))
  val selects = listOf(onAge, onGender, onGroup)
  Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
    Row(Modifier.padding(horizontal = 20.dp)) {
      Text("客層", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
      Text("任意", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
      axes.forEachIndexed { index, (title, options, value) ->
        val current = pager.currentPage == index
        Surface({ go(index) }, Modifier.weight(1f).heightIn(min = 48.dp), shape = MaterialTheme.shapes.small,
          color = if (current) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent,
          border = if (current) null else BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
          Column(Modifier.padding(vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Text(title, style = MaterialTheme.typography.labelLarge, fontWeight = if (current) FontWeight.Bold else null, maxLines = 1)
            Text(options.firstOrNull { it.first == value }?.second ?: "—", style = MaterialTheme.typography.labelSmall, maxLines = 1,
              color = if (value != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
          }
        }
      }
    }
    HorizontalPager(pager, Modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 20.dp), pageSpacing = 20.dp) { page ->
      val (_, options, value) = axes[page]
      Choices(options, value, enabled) { key ->
        val choosing = value != key
        selects[page](key)
        if (choosing) { if (page < 2) go(page + 1) else onDone() }
      }
    }
  }
}
@Composable private fun Choices(options: List<Pair<String, String>>, selected: String?, enabled: Boolean, select: (String) -> Unit) {
  Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
    options.forEach { (key, label) ->
      // A plain toggle instead of FilterChip: the chip's built-in padding wrapped 子ども/シニア onto
      // several lines on narrow phones. One line, no wrap, 48dp touch target.
      val on = selected == key
      Surface({ select(key) }, Modifier.weight(1f).heightIn(min = 48.dp), enabled = enabled, shape = MaterialTheme.shapes.small,
        color = if (on) MaterialTheme.colorScheme.secondary else Color.Transparent,
        contentColor = if (on) MaterialTheme.colorScheme.onSecondary else MaterialTheme.colorScheme.onSurface,
        border = if (on) null else BorderStroke(1.dp, MaterialTheme.colorScheme.outline)) {
        Box(Modifier.padding(horizontal = 2.dp), contentAlignment = Alignment.Center) {
          // Shrinks on narrow screens so カップル / グループ stay on one line.
          Text(label, maxLines = 1, softWrap = false, style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center,
            autoSize = TextAutoSize.StepBased(minFontSize = 9.sp, maxFontSize = MaterialTheme.typography.labelLarge.fontSize))
        }
      }
    }
  }
}
@Composable private fun SingleRegister(
  product: Product, stock: Long?, state: SingleState, extras: ScreenExtras, enabled: Boolean,
  onState: (SingleState) -> Unit, onAge: (String) -> Unit, onGender: (String) -> Unit, onGroup: (String) -> Unit, onConfirm: () -> Unit
) {
  val focus = LocalFocusManager.current
  val list = rememberLazyListState(); val scope = rememberCoroutineScope(); val still = reducedMotion()
  val manualFocus = remember { FocusRequester() }; val keyboard = LocalSoftwareKeyboardController.current
  ScrollToTopAfterSale(extras.customerEpoch, list, still)
  // "手入力" opens an empty field with the numeric keyboard right away.
  LaunchedEffect(state.tender) { if (state.tender == SingleState.MANUAL) runCatching { manualFocus.requestFocus(); keyboard?.show() } }
  val total = state.total(product.price)
  val received = total?.let(state::received)
  val change = if (total != null && received != null && received >= total) received - total else null
  val max = SingleState.maxQuantity(product.stopAtZero, stock)
  val canConfirm = enabled && state.canConfirm(product.price, product.stopAtZero, stock)
  Column(Modifier.fillMaxSize()) {
    LazyColumn(Modifier.weight(1f), state = list, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
      item { Card(shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
          Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            ProductPhoto(product.imageHash, extras.imageGeneration, 88.dp, 20.dp)
            Column(Modifier.weight(1f)) {
              Text(product.name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
              Text("${yen(product.price)} / 本", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
              if (stock != null) Text(if (stock <= 0 && product.stopAtZero) "売り切れ" else "在庫 ${count(stock)}", style = MaterialTheme.typography.labelLarge,
                color = if (stock <= 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
            }
          }
          Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            FilledTonalIconButton({ focus.clearFocus(); onState(state.withQuantity(state.quantity - 1)) }, Modifier.size(72.dp), enabled = enabled && state.quantity > 1) {
              Text("−", Modifier.semantics { contentDescription = "本数を減らす" }, style = MaterialTheme.typography.displaySmall)
            }
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
              Text("${state.quantity}本", style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.ExtraBold)
              Text("合計 ${total?.let(::yen) ?: "上限を超えています"}", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            FilledTonalIconButton({ focus.clearFocus(); onState(state.withQuantity(state.quantity + 1)) }, Modifier.size(72.dp), enabled = enabled && state.quantity < max) {
              Icon(Icons.Default.Add, "本数を増やす", Modifier.size(36.dp))
            }
          }
        }
      } }
      item { Card(shape = RoundedCornerShape(24.dp)) {
        CustomerPager(extras, enabled, onAge, onGender, onGroup) {
          focus.clearFocus(); scope.launch { if (still) list.scrollToItem(2) else list.animateScrollToItem(2) } // show 受け取った額
        }
      } }
      item { Card(shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
          Text("受け取った額", style = MaterialTheme.typography.titleSmall)
          val options = listOf(SingleState.EXACT to "ちょうど") + SingleState.NOTES.map { it.toString() to NumberFormat.getIntegerInstance(Locale.JAPAN).format(it) } + (SingleState.MANUAL to "手入力")
          options.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
              row.forEach { (key, label) ->
                val amount = key.toLongOrNull()
                val on = state.tender == key
                val allowed = enabled && (amount == null || SingleState.enabled(amount, total))
                val colors = if (on) ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.secondary, contentColor = MaterialTheme.colorScheme.onSecondary)
                  else ButtonDefaults.filledTonalButtonColors()
                Button({
                  if (key == SingleState.MANUAL) { onState(state.select(key).copy(manual = "")); if (state.tender == key) runCatching { manualFocus.requestFocus(); keyboard?.show() } }
                  else { focus.clearFocus(); onState(state.select(key)) }
                }, Modifier.weight(1f).heightIn(min = 52.dp), enabled = allowed, colors = colors,
                  contentPadding = PaddingValues(horizontal = 4.dp)) { Text(label, maxLines = 1, style = MaterialTheme.typography.titleMedium) }
              }
            }
          }
          if (state.tender == SingleState.MANUAL) OutlinedTextField(state.manual, { onState(state.copy(manual = it)) }, Modifier.fillMaxWidth().focusRequester(manualFocus), label = { Text("預り金（円）") },
            enabled = enabled, singleLine = true, shape = RoundedCornerShape(16.dp), isError = state.manual.isNotEmpty() && (received == null || total == null || received < total),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }))
        }
      } }
      item { Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.tertiaryContainer, contentColor = MaterialTheme.colorScheme.onTertiaryContainer) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp)) {
          Row(verticalAlignment = Alignment.Bottom) {
            Text("お釣り", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            Text(change?.let(::yen) ?: "—", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.ExtraBold)
          }
          Row {
            Text(change?.let { if (it == 0L) "お釣りなし" else "" } ?: "預り金が足りません", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            if (received != null) Text("預り ${yen(received)}", style = MaterialTheme.typography.bodyMedium)
          }
        }
      } }
    }
    Surface(color = MaterialTheme.colorScheme.background) {
      Action("購入", { focus.clearFocus(); onConfirm() }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), canConfirm)
    }
  }
}
@Composable private fun Register(
  products: List<Product>, cart: List<Line>, cash: String, extras: ScreenExtras, enabled: Boolean, compact: Boolean,
  onCash: (String) -> Unit, onQuantity: (String, Int) -> Unit, onExact: () -> Unit, onCashSet: (Long) -> Unit, onCashAdd: (Long) -> Unit,
  onAge: (String) -> Unit, onGender: (String) -> Unit, onGroup: (String) -> Unit, onCheckout: () -> Unit
) {
  val focus = LocalFocusManager.current
  val list = rememberLazyListState(); val scope = rememberCoroutineScope(); val still = reducedMotion()
  ScrollToTopAfterSale(extras.customerEpoch, list, still)
  val total = runCatching { Money.total(cart) }.getOrNull()
  val received = Money.parse(cash)
  val canPay = enabled && total != null && received != null && received >= total
  fun inCart(id: String) = cart.firstOrNull { it.productID == id }?.quantity ?: 0
  fun canAdd(id: String) = products.firstOrNull { it.id == id }?.let { Cash.canAdd(it.stopAtZero, extras.stocks[id], inCart(id)) } ?: true
  Column(Modifier.fillMaxSize()) {
    LazyColumn(Modifier.weight(1f), state = list, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
      item { Text("商品を選択", Modifier.padding(horizontal = 8.dp), style = MaterialTheme.typography.titleMedium) }
      if (products.isEmpty()) item { Info("商品を登録しましょう", "下の「商品」から、商品名と価格を登録できます。") }
      items(products.chunked(2), key = { "products:${it.first().id}" }) { row ->
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
          row.forEach { product ->
            val stock = extras.stocks[product.id]
            FilledTonalButton(onClick = { focus.clearFocus(); onQuantity(product.id, 1) },
              shapes = ButtonDefaults.shapes(RoundedCornerShape(24.dp), RoundedCornerShape(14.dp)),
              modifier = Modifier.weight(1f).heightIn(min = 100.dp), enabled = enabled && canAdd(product.id), contentPadding = PaddingValues(16.dp)) {
              Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                  ProductPhoto(product.imageHash, extras.imageGeneration, 40.dp, 10.dp)
                  Text(product.name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                }
                Text(yen(product.price), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                // Without stop_at_zero a product keeps selling below zero; the count turns to the warning color.
                if (stock != null) Text(if (stock <= 0 && product.stopAtZero) "売り切れ" else if (stock <= 0) "在庫 ${count(stock)}" else "残り$stock",
                  style = MaterialTheme.typography.labelLarge, color = if (stock <= 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
              }
            }
          }
          if (row.size == 1) Spacer(Modifier.weight(1f))
        }
      }
      item { Text("カート · ${cart.sumOf { it.quantity }}点", Modifier.padding(8.dp), style = MaterialTheme.typography.titleMedium) }
      if (cart.isEmpty()) item { Info("商品をタップして追加", "会計は通信を待たずに端末へ保存します。") }
      items(cart, key = { "cart:${it.productID}" }) { line ->
        Card(shape = RoundedCornerShape(24.dp)) {
          Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
              Text(line.name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
              Text(yen(line.price * line.quantity), style = MaterialTheme.typography.titleMedium)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
              Text("${yen(line.price)} / 点", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
              FilledTonalIconButton(onClick = { focus.clearFocus(); onQuantity(line.productID, -1) }, enabled = enabled, modifier = Modifier.size(48.dp)) {
                Text("−", Modifier.semantics { contentDescription = "${line.name}を減らす" }, style = MaterialTheme.typography.headlineSmall)
              }
              Text("${line.quantity}", Modifier.widthIn(min = 44.dp).wrapContentWidth(), style = MaterialTheme.typography.titleLarge)
              FilledTonalIconButton(onClick = { focus.clearFocus(); onQuantity(line.productID, 1) }, enabled = enabled && line.quantity < 999 && canAdd(line.productID), modifier = Modifier.size(48.dp)) {
                Icon(Icons.Default.Add, "${line.name}を増やす")
              }
            }
          }
        }
      }
      if (cart.isNotEmpty()) item {
        Card(shape = RoundedCornerShape(28.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
          CustomerPager(extras, enabled, onAge, onGender, onGroup) {
            // After 集団: bring the cash card / total and 購入 into view.
            focus.clearFocus(); scope.launch { val last = list.layoutInfo.totalItemsCount - 1; if (last >= 0) { if (still) list.scrollToItem(last) else list.animateScrollToItem(last) } }
          }
        }
      }
      if (cart.isNotEmpty()) item {
        Card(shape = RoundedCornerShape(28.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
          Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(cash, onCash, Modifier.fillMaxWidth(), label = { Text("預り金（円）") }, enabled = enabled,
              singleLine = true, shape = RoundedCornerShape(16.dp), isError = cash.isNotEmpty() && (received == null || total == null || received < total),
              keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }))
            val small = PaddingValues(horizontal = 4.dp)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
              OutlinedButton({ focus.clearFocus(); onExact() }, Modifier.weight(1f).heightIn(min = 48.dp), enabled = enabled && total != null, contentPadding = small) { Text("ちょうど", maxLines = 1) }
              listOf(1000L, 5000L, 10000L).forEach { amount ->
                OutlinedButton({ focus.clearFocus(); onCashSet(amount) }, Modifier.weight(1f).heightIn(min = 48.dp), enabled = enabled, contentPadding = small) { Text(yen(amount), maxLines = 1) }
              }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
              listOf(100L, 500L, 1000L).forEach { amount ->
                FilledTonalButton({ focus.clearFocus(); onCashAdd(amount) }, Modifier.weight(1f).heightIn(min = 48.dp), enabled = enabled, contentPadding = small) { Text("+" + NumberFormat.getIntegerInstance(Locale.JAPAN).format(amount), maxLines = 1) }
              }
              TextButton({ focus.clearFocus(); onCash("") }, Modifier.weight(1f).heightIn(min = 48.dp), enabled = enabled && cash.isNotEmpty(), contentPadding = small) { Text("クリア", maxLines = 1) }
            }
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End) {
              val change = if (total != null && received != null && received >= total) received - total else null
              Text("お釣り", style = MaterialTheme.typography.labelLarge)
              Text(change?.let(::yen) ?: "—", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            }
          }
        }
      }
      if (compact) item { Summary(cart, total, canPay) { focus.clearFocus(); onCheckout() } }
    }
    if (!compact) Summary(cart, total, canPay) { focus.clearFocus(); onCheckout() }
  }
}
@Composable private fun Summary(cart: List<Line>, total: Long?, enabled: Boolean, checkout: () -> Unit) {
  Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)) {
    Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
      Text("合計", style = MaterialTheme.typography.titleMedium)
      Text(if (cart.isEmpty()) yen(0) else total?.let(::yen) ?: "金額上限を超えています", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
      Action("購入", checkout, Modifier.fillMaxWidth(), enabled)
    }
  }
}
private fun parseCounts(text: String): Map<String, Int> = Cash.DENOMINATIONS.zip(text.split(",").map { it.toIntOrNull() ?: 0 } + List(Cash.DENOMINATIONS.size) { 0 })
  .associate { (unit, count) -> unit.toString() to count }
@Composable private fun Counts(counts: Map<String, Int>, enabled: Boolean, change: (Map<String, Int>) -> Unit) {
  Card(shape = RoundedCornerShape(24.dp)) {
    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
      Cash.DENOMINATIONS.forEach { unit ->
        val key = unit.toString(); val count = counts[key] ?: 0
        fun set(value: Int) = change(counts + (key to value.coerceIn(0, 9999)))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
          Text(yen(unit.toLong()), Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
          FilledTonalIconButton({ set(count - 1) }, enabled = enabled && count > 0, modifier = Modifier.size(44.dp)) {
            Text("−", Modifier.semantics { contentDescription = "${unit}円を減らす" }, style = MaterialTheme.typography.titleLarge)
          }
          // Zero shows as an empty field (placeholder "0"): echoing "0" back after a delete puts the
          // cursor in front of it, so typing 5 would become 50.
          OutlinedTextField(if (count == 0) "" else count.toString(), { text -> set(text.filter { it in '0'..'9' }.take(4).toIntOrNull() ?: 0) }, Modifier.width(88.dp),
            enabled = enabled, singleLine = true, placeholder = { Text("0", Modifier.fillMaxWidth(), textAlign = TextAlign.End) }, textStyle = MaterialTheme.typography.titleMedium.copy(textAlign = TextAlign.End),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
          FilledTonalIconButton({ set(count + 1) }, enabled = enabled && count < 9999, modifier = Modifier.size(44.dp)) { Icon(Icons.Default.Add, "${unit}円を増やす") }
        }
      }
    }
  }
}
@Composable private fun Closing(session: DrawerSession?, summary: SessionSummary?, enabled: Boolean, open: (Map<String, Int>) -> Unit, close: (Map<String, Int>) -> Unit) {
  // Counts survive rotation; a new session starts from zero.
  var text by rememberSaveable(session?.id) { mutableStateOf("") }
  var confirm by rememberSaveable(session?.id) { mutableStateOf(false) }
  val counts = parseCounts(text)
  val total = Cash.total(counts)
  fun update(map: Map<String, Int>) { text = Cash.DENOMINATIONS.joinToString(",") { (map[it.toString()] ?: 0).toString() } }
  LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
    if (session == null || summary == null) {
      item { Info("レジ開け", "釣銭準備金を金種ごとに入力して開始します。レジを開けなくても会計はできます（その会計は締めの計算に入りません）。") }
      item { Counts(counts, enabled, ::update) }
      item { Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer), shape = RoundedCornerShape(28.dp)) {
        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
          Text("釣銭準備金", style = MaterialTheme.typography.titleMedium)
          Text(yen(total), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
          Action("レジ開け", { open(counts) }, Modifier.fillMaxWidth(), enabled)
        }
      } }
    } else {
      val expected = Cash.expected(session.floatTotal, summary)
      item { Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer), shape = RoundedCornerShape(28.dp)) {
        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
          Text("現金在高（理論値）", style = MaterialTheme.typography.titleMedium)
          Text(yen(expected), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
          Text("開始 ${jst(session.openedAt)}\n準備金 ${yen(session.floatTotal)}\n会計 ${yen(summary.sales)}（${summary.orders}件）\n取消・返金 ${yen(summary.cancels)}")
          Text("この端末の会計だけを数えます。取消は返金として現金から差し引きます。", style = MaterialTheme.typography.bodySmall)
        }
      } }
      item { Card(shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
          Text("客層別の件数（取消を除く）", style = MaterialTheme.typography.titleMedium)
          if (summary.segments.isEmpty()) Text("まだ会計はありません")
          summary.segments.entries.sortedByDescending { it.value }.forEach { (key, count) -> Text("${Customer.age(key.first)} · ${Customer.gender(key.second)}　${count}件") }
          if (summary.groups.isNotEmpty()) {
            Text("集団別", Modifier.padding(top = 6.dp), style = MaterialTheme.typography.titleSmall)
            (Customer.GROUPS.map { it.first } + listOf<String?>(null)).forEach { key -> summary.groups[key]?.let { Text("${Customer.group(key)}　${it}件") } }
          }
        }
      } }
      item { Text("レジ締め：実際の枚数を数えて入力", Modifier.padding(8.dp), style = MaterialTheme.typography.titleMedium) }
      item { Counts(counts, enabled, ::update) }
      item { Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer), shape = RoundedCornerShape(28.dp)) {
        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
          Text("実際の合計 ${yen(total)}\n理論値 ${yen(expected)}")
          Text("差額 ${difference(total - expected)}", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold,
            color = if (total == expected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.error)
          Action("レジ締め", { confirm = true }, Modifier.fillMaxWidth(), enabled)
        }
      } }
      if (confirm) item { AlertDialog(onDismissRequest = { confirm = false }, title = { Text("レジを締めますか？") },
        text = { Text("実際の合計 ${yen(total)}\n理論値 ${yen(expected)}\n差額 ${difference(total - expected)}\n締めた後は変更できません。") },
        confirmButton = { TextButton({ confirm = false; close(counts) }, enabled = enabled) { Text("締める") } },
        dismissButton = { TextButton({ confirm = false }) { Text("戻る") } }) }
    }
  }
}
private fun count(value: Long) = if (value < 0) "−${-value}" else value.toString()
private fun difference(amount: Long) = if (amount > 0) "+${yen(amount)}" else if (amount < 0) "−${yen(-amount)}" else yen(0)
@Composable private fun History(sales: List<Sale>, enabled: Boolean, cancel: (Sale) -> Unit) {
  val paid = sales.filter { it.cancelledAt == null }
  LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
    item { Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer), shape = RoundedCornerShape(28.dp)) {
      Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("全期間の売上", style = MaterialTheme.typography.titleMedium)
        Text(yen(paid.sumOf { it.total }), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
        Text("会計 ${paid.size}件 · 取消 ${sales.size - paid.size}件")
      }
    } }
    item { Text("右上のアイコンで全件をCSVに書き出せます（確認用。復元用バックアップではありません）。", Modifier.padding(horizontal = 8.dp), style = MaterialTheme.typography.bodySmall) }
    if (sales.isEmpty()) item { Info("まだ会計はありません", "購入すると、ここに履歴が残ります。") }
    items(sales, key = { it.id }) { sale -> Card(shape = RoundedCornerShape(24.dp)) {
      Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
          Text(jst(sale.createdAt), Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
          Text(if (sale.cancelledAt == null) "会計済み" else "取消済み", color = if (sale.cancelledAt == null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error, style = MaterialTheme.typography.labelLarge)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
          Text(yen(sale.total), Modifier.weight(1f), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
          sale.ticketNo?.let { Text("整理番号 $it", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
        }
        Customer.describe(sale.customerAge, sale.customerGender, sale.customerGroup)?.let { Text("客層 $it", style = MaterialTheme.typography.bodySmall) }
        sale.lines.forEach { Text("${it.name} × ${it.quantity}　${yen(it.price * it.quantity)}") }
        Text("預り ${yen(sale.received)} · 釣銭 ${yen(sale.change)}", style = MaterialTheme.typography.bodySmall)
        sale.cancellationReason?.let { Text("取消理由: $it") }
        if (sale.cancelledAt == null) TextButton({ cancel(sale) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) { Text("全額取消・返金記録", color = MaterialTheme.colorScheme.error) }
      }
    } }
  }
}
/** Product photo with rounded corners; the tofu mark when there is none or the file has not arrived yet. */
@Composable fun ProductPhoto(hash: String?, generation: Int, size: androidx.compose.ui.unit.Dp, corner: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
  val context = LocalContext.current
  val pixels = with(LocalDensity.current) { size.roundToPx() }
  val photo by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, hash, generation, pixels) {
    value = hash?.let { h -> withContext(Dispatchers.IO) { runCatching { ProductImages.thumbnail(ProductImages.directory(context), h, pixels)?.asImageBitmap() }.getOrNull() } }
  }
  Box(modifier.size(size).clip(RoundedCornerShape(corner)).background(MaterialTheme.colorScheme.primaryContainer)) {
    val image = photo
    if (image != null) Image(image, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    else Image(painterResource(R.drawable.ic_tofu_foreground), null, Modifier.fillMaxSize())
  }
}
@Composable fun ProductDialog(product: Product?, busy: Boolean, picked: String?, pickToken: Int, imageGeneration: Int, onPick: (android.net.Uri) -> Unit,
  onDismiss: () -> Unit, save: (String, Long, Boolean, Boolean, String?) -> Unit) {
  var name by rememberSaveable(product?.id) { mutableStateOf(product?.name.orEmpty()) }
  var price by rememberSaveable(product?.id) { mutableStateOf(product?.price?.toString().orEmpty()) }
  var active by rememberSaveable(product?.id) { mutableStateOf(product?.active ?: true) }
  var stop by rememberSaveable(product?.id) { mutableStateOf(product?.stopAtZero ?: false) }
  var image by rememberSaveable(product?.id) { mutableStateOf(product?.imageHash) }
  LaunchedEffect(pickToken) { if (pickToken > 0 && picked != null) image = picked }
  // The system photo picker needs no storage permission.
  val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) onPick(uri) }
  val amount = Money.parse(price)
  AlertDialog(onDismissRequest = { if (!busy) onDismiss() }, title = { Text(if (product == null) "商品追加" else "商品編集") }, text = {
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
      OutlinedTextField(name, { name = it }, label = { Text("商品名") }, enabled = !busy, singleLine = true)
      OutlinedTextField(price, { price = it }, label = { Text("価格（円）") }, enabled = !busy, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), isError = price.isNotEmpty() && amount == null)
      Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        ProductPhoto(image, imageGeneration, 72.dp, 16.dp)
        Column(Modifier.weight(1f)) {
          TextButton({ picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, enabled = !busy) { Text("写真を選ぶ") }
          if (image != null) TextButton({ image = null }, enabled = !busy) { Text("写真を外す", color = MaterialTheme.colorScheme.error) }
        }
      }
      Row(verticalAlignment = Alignment.CenterVertically) { Text("販売中（オフでレジに表示しない）", Modifier.weight(1f)); Switch(active, { active = it }, enabled = !busy) }
      Row(verticalAlignment = Alignment.CenterVertically) { Text("在庫0で販売を止める（オフならマイナス在庫でも販売）", Modifier.weight(1f)); Switch(stop, { stop = it }, enabled = !busy) }
      Text("過去の会計とカートの単価は変わりません。保存すると他の端末にも反映します。", style = MaterialTheme.typography.bodySmall)
    }
  }, confirmButton = { TextButton({ if (amount != null) save(name, amount, active, stop, image) }, enabled = !busy && name.isNotBlank() && amount != null) { Text("保存") } },
    dismissButton = { TextButton(onDismiss, enabled = !busy) { Text("戻る") } })
}
@Composable fun StockDialog(product: Product, kind: String, current: Long?, busy: Boolean, onDismiss: () -> Unit, save: (Long, String) -> Unit) {
  var quantity by rememberSaveable(product.id, kind) { mutableStateOf("") }
  var reason by rememberSaveable(product.id, kind) { mutableStateOf("") }
  val value = quantity.takeIf { it.isNotEmpty() && it.length <= 7 && it.all { c -> c in '0'..'9' } }?.toLong()?.takeIf { if (kind == "set") it <= 1_000_000 else it in 1..1_000_000 }
  AlertDialog(onDismissRequest = { if (!busy) onDismiss() }, title = { Text(if (kind == "set") "在庫を数えて設定" else "入荷を追加") }, text = {
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
      Text("${product.name}　現在の在庫 ${current?.toString() ?: "未取得"}")
      OutlinedTextField(quantity, { quantity = it }, label = { Text(if (kind == "set") "数えた在庫数" else "入荷数") }, enabled = !busy, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), isError = quantity.isNotEmpty() && value == null)
      OutlinedTextField(reason, { reason = it }, label = { Text("メモ（任意）") }, enabled = !busy, singleLine = true)
      Text("クラウドに送信すると全端末の在庫に反映します。", style = MaterialTheme.typography.bodySmall)
    }
  }, confirmButton = { TextButton({ if (value != null) save(value, reason) }, enabled = !busy && value != null) { Text("記録") } },
    dismissButton = { TextButton(onDismiss, enabled = !busy) { Text("戻る") } })
}
@Composable fun CheckoutDialog(checkout: Checkout, busy: Boolean, onDismiss: () -> Unit, confirm: () -> Unit) {
  val change = checkout.received - checkout.total
  AlertDialog(onDismissRequest = { if (!busy) onDismiss() }, title = { Text("${yen(checkout.total)} の会計を確定しますか？") },
    text = { Text("預り金 ${yen(checkout.received)}\nお釣り ${yen(change)}\n客層 ${Customer.describe(checkout.age, checkout.gender, checkout.group) ?: "未設定"}") },
    confirmButton = { TextButton(confirm, enabled = !busy) { Text("確定する") } }, dismissButton = { TextButton(onDismiss, enabled = !busy) { Text("戻る") } })
}
@Composable fun ReceiptDialog(sale: Sale, next: () -> Unit) {
  AlertDialog(onDismissRequest = {}, icon = { Icon(Icons.Default.Check, null) }, title = { Text("会計を保存しました") }, text = {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
      sale.ticketNo?.let { Text("整理番号 $it", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.ExtraBold) }
      Text("合計 ${yen(sale.total)}\n預り金 ${yen(sale.received)}")
      Text("お釣り ${yen(sale.change)}", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
      Customer.describe(sale.customerAge, sale.customerGender, sale.customerGroup)?.let { Text("客層 $it", style = MaterialTheme.typography.bodyMedium) }
    }
  }, confirmButton = { Action("次のお客様", next) })
}
@Composable fun CancelDialog(sale: Sale, busy: Boolean, onDismiss: () -> Unit, cancel: (String) -> Unit) {
  var reason by rememberSaveable(sale.id) { mutableStateOf("") }
  var refunded by rememberSaveable(sale.id) { mutableStateOf(false) }
  AlertDialog(onDismissRequest = { if (!busy) onDismiss() }, title = { Text("全額取消") }, text = {
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
      Text("全額 ${yen(sale.total)} を返金してから記録してください。元の会計は残ります。")
      OutlinedTextField(reason, { reason = it }, enabled = !busy, label = { Text("取消理由") })
      Row(verticalAlignment = Alignment.CenterVertically) {
        Checkbox(refunded, { refunded = it }, enabled = !busy)
        Text(if (sale.total == 0L) "0円会計の取消を確認した" else "全額返金を完了した")
      }
    }
  }, confirmButton = { TextButton({ cancel(reason) }, enabled = !busy && reason.isNotBlank() && refunded) { Text("取消を記録") } }, dismissButton = { TextButton(onDismiss, enabled = !busy) { Text("戻る") } })
}
@Composable fun ConnectionDialog(initialUrl: String, busy: Boolean, onDismiss: () -> Unit, save: (String, String) -> Unit) {
  var url by rememberSaveable(initialUrl) { mutableStateOf(initialUrl) }
  // Tokens must never enter saved instance state.
  var token by remember { mutableStateOf("") }
  AlertDialog(onDismissRequest = { if (!busy) onDismiss() }, title = { Text("Cloudflare同期設定") }, text = {
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
      OutlinedTextField(url, { url = it }, label = { Text("https://…workers.dev") }, enabled = !busy, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
      OutlinedTextField(token, { token = it }, label = { Text("端末用トークン") }, supportingText = { Text("空欄なら変更なし") }, enabled = !busy, singleLine = true, visualTransformation = PasswordVisualTransformation())
      Text("レジ専用トークンを使います。初回設定後は同期先URLを変更できません。", style = MaterialTheme.typography.bodySmall)
    }
  }, confirmButton = { TextButton({ save(url, token) }, enabled = !busy && url.isNotBlank()) { Text("保存") } }, dismissButton = { TextButton(onDismiss, enabled = !busy) { Text("戻る") } })
}
@Composable fun ErrorDialog(message: String, dismiss: () -> Unit) {
  AlertDialog(onDismissRequest = dismiss, title = { Text("確認してください") }, text = { Text(message) }, confirmButton = { TextButton(dismiss) { Text("閉じる") } })
}

@Composable fun CatalogDialog(catalogs: List<Catalog>, hasMore: Boolean, loading: Boolean, more: () -> Unit, dismiss: () -> Unit, select: (Catalog?) -> Unit) {
  AlertDialog(onDismissRequest=dismiss, title={ Text("商品バックアップを選択") }, text={
    Column(Modifier.heightIn(max=400.dp).verticalScroll(rememberScrollState()), verticalArrangement=Arrangement.spacedBy(8.dp)) {
      Text("商品バックアップは新しい順に表示します。過去の分は「さらに表示」で選べます。売上は現在のクラウド保存内容から復元します。")
      OutlinedButton({ select(null) }, Modifier.fillMaxWidth()) { Text("売上のみ復元") }
      catalogs.forEach { c -> OutlinedButton({ select(c) }, Modifier.fillMaxWidth(), enabled = !loading) { Text("${jst(c.receivedAt)} · 商品${c.productCount}件") } }
      if (hasMore) OutlinedButton(more, Modifier.fillMaxWidth(), enabled = !loading) { Text(if (loading) "読み込み中…" else "さらに表示") }
    }
  }, confirmButton={ TextButton(dismiss) { Text("戻る") } })
}
@Composable fun RestoreConfirmDialog(catalog: Catalog?, continuation: Boolean, dismiss: () -> Unit, restore: () -> Unit) {
  AlertDialog(onDismissRequest=dismiss, title={ Text(if (continuation) "売上の続きを復元" else "クラウドから復元") },
    text={ Text((catalog?.let { "${jst(it.receivedAt)} の商品${it.productCount}件と、" } ?: "") + "売上を最大50件取り込みます。端末の既存データは削除せず、内容の異なる商品・会計は保持します。取消済みの会計を元に戻しません。") },
    confirmButton={ TextButton(restore) { Text("復元する") } }, dismissButton={ TextButton(dismiss) { Text("戻る") } })
}
