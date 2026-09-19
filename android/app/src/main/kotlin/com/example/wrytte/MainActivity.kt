package com.example.wrytte

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.providers.NNAPIFlags
import android.content.Context
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.util.Log
import android.media.ToneGenerator
import android.os.Bundle
import android.telephony.TelephonyManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.UUID
import java.util.EnumSet
import java.util.concurrent.ConcurrentHashMap

class MainActivity: FlutterActivity() {

    private data class NativeOrtSession(
        val session: OrtSession,
        val executionProvider: String,
        var inputBuffer: ByteBuffer? = null,
        val outputBuffers: ConcurrentHashMap<String, FloatArray> = ConcurrentHashMap(),
        var closed: Boolean = false,
    )

    private val deviceRegionChannel = "com.example.wrytte/device_region"
    private val callerRingbackChannel = "com.example.wrytte/caller_ringback"
    private val onnxImageChannel = "com.example.wrytte/onnx_image"
    private val cameraCapabilitiesChannel = "com.example.wrytte/camera_capabilities"
    private var callerRingback: ToneGenerator? = null
    private val ortEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private val ortSessions = ConcurrentHashMap<String, NativeOrtSession>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cameraCapabilitiesChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "getFpsRanges") {
                    result.notImplemented(); return@setMethodCallHandler
                }
                try {
                    val cameraId = call.argument<String>("cameraId")
                        ?: throw IllegalArgumentException("cameraId is required")
                    val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    val ranges = manager.getCameraCharacteristics(cameraId)
                        .get(android.hardware.camera2.CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                        ?.map { listOf(it.lower, it.upper) }
                        ?: emptyList()
                    result.success(ranges)
                } catch (error: Throwable) {
                    result.error("CAMERA_CAPABILITIES_ERROR", error.message, null)
                }
            }
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            callerRingbackChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    stopCallerRingback()
                    callerRingback = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80).also {
                        it.startTone(ToneGenerator.TONE_SUP_RINGTONE)
                    }
                    result.success(null)
                }
                "stop" -> {
                    stopCallerRingback()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ONNX sessions belong to independent, stage-gated models. A serial
        // task queue silently turned Dart Future.wait calls into sequential
        // native inference. Allow different sessions (RetinaFace, AdaFace and
        // both MiniFAS models) to execute at the same time.
        val backgroundQueue =
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue(
                BinaryMessenger.TaskQueueOptions().setIsSerial(false),
            )
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
                        val requestedThreads = call.argument<Int>("threads") ?: 4
                        val requireHardwareAcceleration =
                            call.argument<Boolean>("requireHardwareAcceleration") == true
                        // Keep one persistent session. CPU thread settings
                        // apply only when RetinaFace must use its CPU fallback.
                        val threads = requestedThreads
                            .coerceAtLeast(1)
                            .coerceAtMost(Runtime.getRuntime().availableProcessors().coerceAtLeast(1))
                        val model = materializeFlutterAsset(asset)
                        val (session, executionProvider) = createOrtSession(
                            model = model,
                            threads = threads,
                            requireHardwareAcceleration = requireHardwareAcceleration,
                        )
                        val id = UUID.randomUUID().toString()
                        ortSessions[id] = NativeOrtSession(session, executionProvider)
                        result.success(
                            mapOf(
                                "sessionId" to id,
                                "inputNames" to session.inputNames.toList(),
                                "outputNames" to session.outputNames.toList(),
                                "executionProvider" to executionProvider,
                            ),
                        )
                    }
                    "runBgr" -> result.success(runBgr(call.arguments as Map<*, *>))
                    "closeSession" -> {
                        call.argument<String>("sessionId")?.let { id ->
                            ortSessions.remove(id)?.let { closeOrtSession(it) }
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

    /**
     * RetinaFace requests NNAPI with its CPU device disabled. NNAPI may select
     * a compatible GPU or NPU; it is not a promise that a particular Android
     * device exposes either one. If the full model cannot run on hardware,
     * session creation deliberately falls back to the regular ORT CPU path.
     */
    private fun createOrtSession(
        model: File,
        threads: Int,
        requireHardwareAcceleration: Boolean,
    ): Pair<OrtSession, String> {
        fun cpuOptions() = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(threads)
            setInterOpNumThreads(1)
            setCPUArenaAllocator(true)
        }
        if (requireHardwareAcceleration && android.os.Build.VERSION.SDK_INT >= 29) {
            val hardwareOptions = cpuOptions()
            try {
                // CPU_DISABLED prevents NNAPI itself choosing its reference
                // CPU device. disable_cpu_ep_fallback makes this an all-or-
                // nothing hardware session, rather than mixing hidden CPU
                // graph partitions into a claimed accelerated session.
                hardwareOptions.addNnapi(
                    EnumSet.of(NNAPIFlags.CPU_DISABLED, NNAPIFlags.USE_NCHW),
                )
                hardwareOptions.addConfigEntry("session.disable_cpu_ep_fallback", "1")
                return ortEnvironment.createSession(model.absolutePath, hardwareOptions) to "nnapi_hardware"
            } catch (error: Throwable) {
                // A model/operator or device driver is not hardware capable.
                // This has no biometric data; it makes CPU fallback diagnosable
                // on the affected phone.
                Log.w(
                    "WrytteOnnx",
                    "RetinaFace NNAPI hardware initialization failed; using CPU fallback: " +
                        "${error.javaClass.simpleName}: ${error.message}",
                    error,
                )
            } finally {
                hardwareOptions.close()
            }
        }
        val options = cpuOptions()
        return try {
            ortEnvironment.createSession(model.absolutePath, options) to "cpu"
        } finally {
            options.close()
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
        return synchronized(nativeSession) {
            check(!nativeSession.closed) { "Session is closed" }
            try {
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
                    // MiniFASNet's backend reference consumes RGB NCHW.
                    // [bytes] is BGR, so write the planes in R/G/B order.
                    floats.put(pixel, red.toFloat())
                    floats.put(plane + pixel, green.toFloat())
                    floats.put((plane * 2) + pixel, blue.toFloat())
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
                        session.outputNames.associateWith { name ->
                            val tensor = outputs[name].get() as OnnxTensor
                            val buffer: FloatBuffer = tensor.floatBuffer
                            val valueCount = buffer.remaining()
                            val values = nativeSession.outputBuffers.compute(name) { _, current ->
                                if (current == null || current.size != valueCount) {
                                    FloatArray(valueCount)
                                } else {
                                    current
                                }
                            }!!
                            buffer.get(values, 0, valueCount)
                            // The channel owns the returned snapshot; reusable session
                            // buffers can be erased before another worker call arrives.
                            values.copyOf()
                        }
                    }
                }
            } finally {
                bytes.fill(0)
                wipeOrtBuffers(nativeSession)
            }
        }
    }

    private fun wipeOrtBuffers(native: NativeOrtSession) {
        native.inputBuffer?.let { buffer ->
            buffer.clear()
            while (buffer.hasRemaining()) buffer.put(0.toByte())
            buffer.clear()
        }
        native.outputBuffers.values.forEach { it.fill(0f) }
    }

    private fun closeOrtSession(native: NativeOrtSession) = synchronized(native) {
        if (!native.closed) {
            native.closed = true
            try { native.session.close() } finally {
                wipeOrtBuffers(native)
                native.inputBuffer = null
                native.outputBuffers.clear()
            }
        }
    }

    override fun onDestroy() {
        stopCallerRingback()
        ortSessions.values.forEach { closeOrtSession(it) }
        ortSessions.clear()
        super.onDestroy()
    }

    private fun stopCallerRingback() {
        callerRingback?.stopTone()
        callerRingback?.release()
        callerRingback = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 🔥 REQUIRED FOR EDGE TO EDGE
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }
}
