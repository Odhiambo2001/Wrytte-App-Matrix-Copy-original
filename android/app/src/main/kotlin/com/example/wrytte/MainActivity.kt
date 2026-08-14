package com.example.wrytte

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.os.Bundle
import android.telephony.TelephonyManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.FlutterInjector
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class MainActivity: FlutterActivity() {

    private data class NativeOrtSession(
        val session: OrtSession,
        var inputBuffer: ByteBuffer? = null,
    )

    private val deviceRegionChannel = "com.example.wrytte/device_region"
    private val onnxImageChannel = "com.example.wrytte/onnx_image"
    private val ortEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private val ortSessions = ConcurrentHashMap<String, NativeOrtSession>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            deviceRegionChannel,
        ).setMethodCallHandler { call, result ->
            if (call.method != "getRegionCode") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val telephony = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            val region = sequenceOf(
                telephony.networkCountryIso,
                telephony.simCountryIso,
                resources.configuration.locales.get(0).country,
            ).map { it.trim().uppercase() }
                .firstOrNull { it.matches(Regex("^[A-Z]{2}$")) }
            result.success(region)
        }

        val backgroundQueue =
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue()
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            onnxImageChannel,
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            backgroundQueue,
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "createSession" -> {
                        val asset = requireNotNull(call.argument<String>("asset"))
                        val threads = call.argument<Int>("threads") ?: 2
                        val model = materializeFlutterAsset(asset)
                        val options = OrtSession.SessionOptions().apply {
                            setIntraOpNumThreads(threads)
                            setInterOpNumThreads(1)
                            setCPUArenaAllocator(true)
                        }
                        val session = ortEnvironment.createSession(model.absolutePath, options)
                        val id = UUID.randomUUID().toString()
                        ortSessions[id] = NativeOrtSession(session)
                        result.success(
                            mapOf(
                                "sessionId" to id,
                                "inputNames" to session.inputNames.toList(),
                                "outputNames" to session.outputNames.toList(),
                            ),
                        )
                    }
                    "runBgr" -> result.success(runBgr(call.arguments as Map<*, *>))
                    "closeSession" -> {
                        call.argument<String>("sessionId")?.let { id ->
                            ortSessions.remove(id)?.session?.close()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Throwable) {
                result.error("NATIVE_ONNX_ERROR", error.message, error.stackTraceToString())
            }
        }
    }

    private fun materializeFlutterAsset(asset: String): File {
        val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
        val output = File(cacheDir, "wrytte_onnx_${asset.substringAfterLast('/')}")
        if (!output.exists() || output.length() == 0L) {
            assets.open(key).use { input -> output.outputStream().use(input::copyTo) }
        }
        return output
    }

    private fun runBgr(arguments: Map<*, *>): Map<String, FloatArray> {
        val sessionId = requireNotNull(arguments["sessionId"] as? String)
        val inputName = requireNotNull(arguments["inputName"] as? String)
        val bytes = requireNotNull(arguments["bgr"] as? ByteArray)
        val width = (arguments["width"] as Number).toInt()
        val height = (arguments["height"] as Number).toInt()
        val mode = requireNotNull(arguments["mode"] as? String)
        require(bytes.size == width * height * 3) { "Invalid BGR buffer length" }
        val nativeSession = requireNotNull(ortSessions[sessionId]) { "Session is closed" }
        val session = nativeSession.session

        val plane = width * height
        val requiredBytes = plane * 3 * Float.SIZE_BYTES
        var directBytes = nativeSession.inputBuffer
        if (directBytes == null || directBytes.capacity() != requiredBytes) {
            directBytes = ByteBuffer.allocateDirect(requiredBytes)
                .order(ByteOrder.nativeOrder())
            nativeSession.inputBuffer = directBytes
        }
        directBytes.clear()
        val floats = directBytes.asFloatBuffer()
        for (pixel in 0 until plane) {
            val source = pixel * 3
            val blue = bytes[source].toInt() and 0xff
            val green = bytes[source + 1].toInt() and 0xff
            val red = bytes[source + 2].toInt() and 0xff
            when (mode) {
                "retina" -> {
                    floats.put(pixel, blue - 104f)
                    floats.put(plane + pixel, green - 117f)
                    floats.put((plane * 2) + pixel, red - 123f)
                }
                "mini_fas" -> {
                    floats.put(pixel, blue.toFloat())
                    floats.put(plane + pixel, green.toFloat())
                    floats.put((plane * 2) + pixel, red.toFloat())
                }
                "adaface" -> {
                    floats.put(pixel, (red / 127.5f) - 1f)
                    floats.put(plane + pixel, (green / 127.5f) - 1f)
                    floats.put((plane * 2) + pixel, (blue / 127.5f) - 1f)
                }
                "retina_rgb" -> {
                    val rgbRed = blue
                    val rgbBlue = red
                    floats.put(pixel, rgbBlue - 104f)
                    floats.put(plane + pixel, green - 117f)
                    floats.put((plane * 2) + pixel, rgbRed - 123f)
                }
                "mini_fas_rgb" -> {
                    val rgbRed = blue
                    val rgbBlue = red
                    floats.put(pixel, rgbBlue.toFloat())
                    floats.put(plane + pixel, green.toFloat())
                    floats.put((plane * 2) + pixel, rgbRed.toFloat())
                }
                "adaface_rgb" -> {
                    val rgbRed = blue
                    val rgbBlue = red
                    floats.put(pixel, (rgbRed / 127.5f) - 1f)
                    floats.put(plane + pixel, (green / 127.5f) - 1f)
                    floats.put((plane * 2) + pixel, (rgbBlue / 127.5f) - 1f)
                }
                else -> error("Unknown preprocessing mode: $mode")
            }
        }

        OnnxTensor.createTensor(
            ortEnvironment,
            floats,
            longArrayOf(1, 3, height.toLong(), width.toLong()),
        ).use { input ->
            session.run(mapOf(inputName to input)).use { outputs ->
                return session.outputNames.associateWith { name ->
                    val tensor = outputs[name].get() as OnnxTensor
                    val buffer: FloatBuffer = tensor.floatBuffer
                    FloatArray(buffer.remaining()).also(buffer::get)
                }
            }
        }
    }

    override fun onDestroy() {
        ortSessions.values.forEach { it.session.close() }
        ortSessions.clear()
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 🔥 REQUIRED FOR EDGE TO EDGE
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }
}
