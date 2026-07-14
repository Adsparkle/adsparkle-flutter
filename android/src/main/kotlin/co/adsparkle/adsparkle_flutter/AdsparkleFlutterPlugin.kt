package co.adsparkle.adsparkle_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.net.URLDecoder

/**
 * Android deferred (install) attribution — Play Install Referrer reader.
 *
 * Exposes a single MethodChannel method `getInstallReferrer` that opens an
 * [InstallReferrerClient], reads the referrer, and returns the extracted
 * `click_id` (or null). Unlike iOS this is DETERMINISTIC: the Play Store carries
 * `referrer=click_id=<uuid>` through the store install.
 *
 * The public API surface stays consistent across SDKs — merchants call only
 * `AdSparkle.instance.configure()`; this native side is internal.
 *
 * Parse logic is IDENTICAL to the native Android SDK's InstallReferrerReader.
 */
class AdsparkleFlutterPlugin : FlutterPlugin, MethodCallHandler {

  private lateinit var channel: MethodChannel
  private var applicationContext: Context? = null

  // MethodChannel.Result must be answered on the platform (main) thread, but the
  // InstallReferrer callbacks arrive on a background service thread — marshal back.
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    applicationContext = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    applicationContext = null
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    if (call.method != "getInstallReferrer") {
      result.notImplemented()
      return
    }
    val ctx = applicationContext
    if (ctx == null) {
      result.success(null)
      return
    }
    readInstallReferrer(ctx) { clickId ->
      // Answer on the main thread (see mainHandler note).
      mainHandler.post { result.success(clickId) }
    }
  }

  /**
   * Reads the Play Install Referrer once and invokes [onResult] exactly once with
   * the extracted click_id (or null). Never throws.
   */
  private fun readInstallReferrer(context: Context, onResult: (String?) -> Unit) {
    val client = try {
      InstallReferrerClient.newBuilder(context).build()
    } catch (e: Throwable) {
      onResult(null)
      return
    }

    var delivered = false
    fun deliverOnce(value: String?) {
      if (!delivered) {
        delivered = true
        onResult(value)
      }
    }

    try {
      client.startConnection(object : InstallReferrerStateListener {
        override fun onInstallReferrerSetupFinished(responseCode: Int) {
          var clickId: String? = null
          try {
            if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
              clickId = parseClickId(client.installReferrer.installReferrer)
            }
          } catch (_: Throwable) {
            // ignore — deliver null below
          } finally {
            try { client.endConnection() } catch (_: Throwable) { /* no-op */ }
          }
          deliverOnce(clickId)
        }

        override fun onInstallReferrerServiceDisconnected() {
          // No retry: the referrer is immutable and the Dart-side referrerChecked
          // flag already prevents a re-query on the next launch.
        }
      })
    } catch (e: Throwable) {
      try { client.endConnection() } catch (_: Throwable) { /* no-op */ }
      deliverOnce(null)
    }
  }

  /**
   * Extracts the `click_id` value from a referrer string
   * ("click_id=<uuid>&utm_source=..."). Returns null when absent.
   *
   * URL-decode first (idempotent for a UUID, so it also handles a still-encoded
   * "click_id%3D<uuid>"), then scan the `&`-separated pairs for `click_id`.
   */
  private fun parseClickId(rawReferrer: String?): String? {
    if (rawReferrer.isNullOrEmpty()) return null
    val referrer = try {
      URLDecoder.decode(rawReferrer, "UTF-8")
    } catch (_: Throwable) {
      rawReferrer
    }
    for (pair in referrer.split("&")) {
      val idx = pair.indexOf('=')
      if (idx <= 0) continue
      if (pair.substring(0, idx) == "click_id") {
        val v = pair.substring(idx + 1)
        return if (v.isEmpty()) null else v
      }
    }
    return null
  }

  companion object {
    // Must match the Dart channel name in install_referrer.dart.
    private const val CHANNEL_NAME = "co.adsparkle/install_referrer"
  }
}
