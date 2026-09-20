package com.example.wrytte

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtLoggingLevel
import ai.onnxruntime.OrtSession
import ai.onnxruntime.providers.NNAPIFlags
import android.content.Context
import android.graphics.Bitmap
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.util.Log
import android.media.ToneGenerator
import android.os.Bundle
import android.os.SystemClock
import android.telephony.TelephonyManager
import androidx.core.view.WindowCompat
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.view.TextureRegistry
import android.view.Surface
import java.io.File
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.UUID
import java.util.EnumSet
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private data class RetinaPrior(
    val centerX: Float,
    val centerY: Float,
    val width: Float,
    val height: Float,
)

private data class RetinaCandidate(
    val left: Double,
    val top: Double,
    val right: Double,
    val bottom: Double,
    val rawLeft: Double,
    val rawTop: Double,
    val rawRight: Double,
    val rawBottom: Double,
    val confidence: Double,
    val landmarks: DoubleArray,
)

private data class RetinaDecodeResult(
    val faces: List<Map<String, Any>>,
    val bestFaceConfidence: Double,
)

class MainActivity: FlutterActivity() {

    private data class NativeOrtSession(
        val session: OrtSession,
        val executionProvider: String,
        var inputBuffer: ByteBuffer? = null,
        val outputBuffers: ConcurrentHashMap<String, FloatArray> = ConcurrentHashMap(),
        var closed: Boolean = false,
    )

    private data class NativeTfliteSession(
        val interpreter: Interpreter,
        val gpuDelegate: GpuDelegate?,
        val executionProvider: String,
        val inputBuffer: ByteBuffer,
        val outputBuffers: List<ByteBuffer>,
        val retinaPriors: List<RetinaPrior>,
        var closed: Boolean = false,
    )

    private val deviceRegionChannel = "com.example.wrytte/device_region"
    private val callerRingbackChannel = "com.example.wrytte/caller_ringback"
    private val onnxImageChannel = "com.example.wrytte/onnx_image"
    private val tfliteImageChannel = "com.example.wrytte/tflite_image"
    private val nativeFaceCameraChannel = "com.example.wrytte/native_face_camera"
    private val nativeFaceCameraEvents = "com.example.wrytte/native_face_camera/events"
    private val cameraCapabilitiesChannel = "com.example.wrytte/camera_capabilities"
    private var callerRingback: ToneGenerator? = null
    private val ortEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private val ortSessions = ConcurrentHashMap<String, NativeOrtSession>()
    private val tfliteSessions = ConcurrentHashMap<String, NativeTfliteSession>()
    private var nativeFaceCamera: NativeFaceCamera? = null
    private var nativeFaceEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, nativeFaceCameraEvents)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    nativeFaceEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    nativeFaceEventSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nativeFaceCameraChannel)
            .setMethodCallHandler { call, result ->
                val scanner = nativeFaceCamera
                try {
                    when (call.method) {
                        "textureId" -> {
                            val instance = scanner ?: NativeFaceCamera(flutterEngine.renderer).also {
                                nativeFaceCamera = it
                            }
                            instance.start()
                            result.success(instance.textureId)
                        }
                        "stop" -> { scanner?.stop(); result.success(null) }
                        "reset" -> { scanner?.reset(); result.success(null) }
                        "livenessCrop" -> {
                            requireNotNull(scanner) { "Native camera is not initialized" }
                            scanner.livenessCrop(call.arguments as Map<*, *>, result)
                        }
                        "takeJpeg" -> {
                            requireNotNull(scanner) { "Native camera is not initialized" }
                            scanner.takeJpeg(call.arguments as Map<*, *>, result)
                        }
                        "discard" -> {
                            scanner?.discard((call.argument<Number>("frameId") ?: -1).toInt())
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Throwable) {
                    result.error("NATIVE_CAMERA_ERROR", error.message, error.stackTraceToString())
                }
            }
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

        // GPU delegates must be created and invoked from the same thread.
        // This serial platform queue keeps every persistent RetinaFace session
        // thread-affine without blocking Flutter's UI isolate.
        val tfliteQueue = flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue()
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            tfliteImageChannel,
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            tfliteQueue,
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "createRetinaFaceSession" -> {
                        val asset = requireNotNull(call.argument<String>("asset"))
                        val threads = (call.argument<Int>("threads") ?: 4)
                            .coerceAtLeast(1)
                            .coerceAtMost(Runtime.getRuntime().availableProcessors().coerceAtLeast(1))
                        val native = createTfliteRetinaFaceSession(
                            materializeFlutterAsset(asset),
                            threads,
                        )
                        val id = UUID.randomUUID().toString()
                        tfliteSessions[id] = native
                        result.success(
                            mapOf(
                                "sessionId" to id,
                                "executionProvider" to native.executionProvider,
                            ),
                        )
                    }
                    "runBgr" -> result.success(runTfliteRetinaBgr(call.arguments as Map<*, *>))
                    "closeSession" -> {
                        call.argument<String>("sessionId")?.let { id ->
                            tfliteSessions.remove(id)?.let { closeTfliteSession(it) }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Throwable) {
                Log.e(
                    "WrytteLiteRT",
                    "RetinaFace LiteRT method=${call.method} failed: " +
                        "${error.javaClass.simpleName}: ${error.message}",
                    error,
                )
                result.error("NATIVE_TFLITE_ERROR", error.message, error.stackTraceToString())
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
                // Make ONNX Runtime emit graph-partition diagnostics. In
                // particular, this lets logcat report which model nodes are
                // not assigned to NNAPI when the all-hardware session fails.
                hardwareOptions.setSessionLogLevel(
                    OrtLoggingLevel.ORT_LOGGING_LEVEL_VERBOSE,
                )
                hardwareOptions.setSessionLogVerbosityLevel(1)
                hardwareOptions.addConfigEntry("session.disable_cpu_ep_fallback", "1")
                Log.i(
                    "WrytteOnnx",
                    "Creating strict RetinaFace NNAPI session with verbose graph-partition logging",
                )
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

    /**
     * Creates a LiteRT RetinaFace interpreter with the GPU delegate when the
     * device reports GPU support. If GPU setup is unavailable, retain a CPU
     * interpreter as the device-compatibility fallback. The app logs the
     * selected provider for every detector initialization.
     */
    private fun createTfliteRetinaFaceSession(model: File, threads: Int): NativeTfliteSession {
        val compatibility = CompatibilityList()
        var gpuDelegate: GpuDelegate? = null
        var provider = "cpu"
        val options = Interpreter.Options()
        try {
            if (compatibility.isDelegateSupportedOnThisDevice) {
                // Use the device-specific GPU options selected by LiteRT. The
                // delegate and interpreter are retained for the whole scan;
                // neither is recreated for an individual camera frame.
                gpuDelegate = GpuDelegate(compatibility.bestOptionsForThisDevice)
                options.addDelegate(gpuDelegate)
                provider = "gpu"
                Log.i("WrytteLiteRT", "RetinaFace LiteRT GPU delegate initialized")
            } else {
                options.setNumThreads(threads)
                Log.w("WrytteLiteRT", "RetinaFace GPU delegate unavailable; using CPU fallback")
            }
            val interpreter = Interpreter(model, options)
            interpreter.allocateTensors()
            val input = interpreter.getInputTensor(0)
            require(input.numBytes() == 640 * 640 * 3 * Float.SIZE_BYTES) {
                "Unexpected RetinaFace LiteRT input shape ${input.shape().contentToString()}"
            }
            val outputs = (0 until interpreter.outputTensorCount).map { index ->
                ByteBuffer.allocateDirect(interpreter.getOutputTensor(index).numBytes())
                    .order(ByteOrder.nativeOrder())
            }
            require(outputs.size == 3) { "Unexpected RetinaFace LiteRT output count ${outputs.size}" }
            Log.i(
                "WrytteLiteRT",
                "RetinaFace LiteRT session ready provider=$provider " +
                    "input=${input.shape().contentToString()} " +
                    "outputs=${(0 until interpreter.outputTensorCount).joinToString { interpreter.getOutputTensor(it).shape().contentToString() }}",
            )
            return NativeTfliteSession(
                interpreter = interpreter,
                gpuDelegate = gpuDelegate,
                executionProvider = provider,
                inputBuffer = ByteBuffer.allocateDirect(input.numBytes()).order(ByteOrder.nativeOrder()),
                outputBuffers = outputs,
                retinaPriors = createRetinaPriors(),
            )
        } catch (error: Throwable) {
            try { gpuDelegate?.close() } catch (_: Throwable) {}
            throw error
        }
    }

    private fun runTfliteRetinaBgr(arguments: Map<*, *>): Map<String, Any> {
        val sessionId = requireNotNull(arguments["sessionId"] as? String)
        val bytes = requireNotNull(arguments["bgr"] as? ByteArray)
        val width = (arguments["width"] as Number).toInt()
        val height = (arguments["height"] as Number).toInt()
        require(width == 640 && height == 640 && bytes.size == width * height * 3) {
            "LiteRT RetinaFace requires packed 640x640 BGR pixels"
        }
        val native = requireNotNull(tfliteSessions[sessionId]) { "Session is closed" }
        return synchronized(native) {
            check(!native.closed) { "Session is closed" }
            try {
                val frameStartedAt = SystemClock.elapsedRealtimeNanos()
                // Converted LiteRT input is NHWC, but its channels preserve
                // ONNX RetinaFace's B/G/R mean-subtracted semantics.
                native.inputBuffer.clear()
                val floats = native.inputBuffer.asFloatBuffer()
                for (pixel in 0 until width * height) {
                    val offset = pixel * 3
                    floats.put((bytes[offset].toInt() and 0xff) - 104f)
                    floats.put((bytes[offset + 1].toInt() and 0xff) - 117f)
                    floats.put((bytes[offset + 2].toInt() and 0xff) - 123f)
                }
                native.inputBuffer.position(0)
                val preprocessingMs =
                    (SystemClock.elapsedRealtimeNanos() - frameStartedAt) / 1_000_000.0
                native.outputBuffers.forEach { it.clear() }
                val invokeStartedAt = SystemClock.elapsedRealtimeNanos()
                native.interpreter.runForMultipleInputsOutputs(
                    arrayOf(native.inputBuffer),
                    native.outputBuffers.indices.associateWith { native.outputBuffers[it] },
                )
                val invokeMs =
                    (SystemClock.elapsedRealtimeNanos() - invokeStartedAt) / 1_000_000.0
                val decodeStartedAt = SystemClock.elapsedRealtimeNanos()
                val decoded = decodeRetinaFaces(native)
                val decodeMs =
                    (SystemClock.elapsedRealtimeNanos() - decodeStartedAt) / 1_000_000.0
                val totalMs = (SystemClock.elapsedRealtimeNanos() - frameStartedAt) / 1_000_000.0
                Log.i(
                    "WrytteLiteRT",
                    "RetinaFace frame provider=${native.executionProvider} " +
                        "preprocess_ms=%.1f invoke_ms=%.1f decode_nms_ms=%.1f faces=%d total_native_ms=%.1f"
                            .format(preprocessingMs, invokeMs, decodeMs, decoded.faces.size, totalMs) +
                        " best_face_conf=%.4f".format(decoded.bestFaceConfidence),
                )
                mapOf("faces" to decoded.faces)
            } finally {
                bytes.fill(0)
                native.inputBuffer.clear()
                while (native.inputBuffer.hasRemaining()) native.inputBuffer.put(0.toByte())
                native.inputBuffer.clear()
                native.outputBuffers.forEach { buffer ->
                    buffer.clear()
                    while (buffer.hasRemaining()) buffer.put(0.toByte())
                    buffer.clear()
                }
            }
        }
    }

    /**
     * Decodes, confidence-filters and NMS-filters RetinaFace directly beside
     * the LiteRT interpreter. This deliberately avoids sending ~1 MiB of
     * raw output tensors over the platform channel for each camera frame.
     */
    private fun decodeRetinaFaces(native: NativeTfliteSession): RetinaDecodeResult {
        // Interpreter writes into the supplied direct buffers. Explicitly
        // rewind each view before reading, matching the former proven Dart
        // bridge implementation and avoiding a stale inherited position.
        val locations = native.outputBuffers[0].duplicate().order(ByteOrder.nativeOrder()).apply { clear() }
            .asFloatBuffer()
        val scores = native.outputBuffers[1].duplicate().order(ByteOrder.nativeOrder()).apply { clear() }
            .asFloatBuffer()
        val landmarks = native.outputBuffers[2].duplicate().order(ByteOrder.nativeOrder()).apply { clear() }
            .asFloatBuffer()
        val candidates = ArrayList<RetinaCandidate>()
        val count = minOf(native.retinaPriors.size, locations.capacity() / 4, scores.capacity() / 2)
        var bestFaceConfidence = 0.0
        for (index in 0 until count) {
            val confidence = scores.get(index * 2 + 1).toDouble()
            if (confidence > bestFaceConfidence) bestFaceConfidence = confidence
            if (confidence < 0.60) continue
            val prior = native.retinaPriors[index]
            val locationOffset = index * 4
            val centerX = prior.centerX + locations.get(locationOffset) * 0.1f * prior.width
            val centerY = prior.centerY + locations.get(locationOffset + 1) * 0.1f * prior.height
            val width = prior.width * kotlin.math.exp(locations.get(locationOffset + 2) * 0.2f)
            val height = prior.height * kotlin.math.exp(locations.get(locationOffset + 3) * 0.2f)
            val rawLeft = (centerX - width / 2f) * 640.0
            val rawTop = (centerY - height / 2f) * 640.0
            val rawRight = (centerX + width / 2f) * 640.0
            val rawBottom = (centerY + height / 2f) * 640.0
            val landmarkValues = DoubleArray(10)
            val landmarkOffset = index * 10
            for (point in 0 until 5) {
                landmarkValues[point * 2] =
                    (prior.centerX + landmarks.get(landmarkOffset + point * 2) * 0.1f * prior.width) * 640.0
                landmarkValues[point * 2 + 1] =
                    (prior.centerY + landmarks.get(landmarkOffset + point * 2 + 1) * 0.1f * prior.height) * 640.0
            }
            candidates += RetinaCandidate(
                left = rawLeft.coerceIn(0.0, 640.0),
                top = rawTop.coerceIn(0.0, 640.0),
                right = rawRight.coerceIn(0.0, 640.0),
                bottom = rawBottom.coerceIn(0.0, 640.0),
                rawLeft = rawLeft,
                rawTop = rawTop,
                rawRight = rawRight,
                rawBottom = rawBottom,
                confidence = confidence,
                landmarks = landmarkValues,
            )
        }
        candidates.sortByDescending { it.confidence }
        val selected = ArrayList<RetinaCandidate>()
        for (candidate in candidates) {
            if (selected.all { iou(candidate, it) <= 0.40 }) selected += candidate
        }
        return RetinaDecodeResult(selected.map { face ->
            mapOf(
                "left" to face.left,
                "top" to face.top,
                "right" to face.right,
                "bottom" to face.bottom,
                "rawLeft" to face.rawLeft,
                "rawTop" to face.rawTop,
                "rawRight" to face.rawRight,
                "rawBottom" to face.rawBottom,
                "confidence" to face.confidence,
                "landmarks" to face.landmarks.toList(),
            )
        }, bestFaceConfidence)
    }

    private fun iou(a: RetinaCandidate, b: RetinaCandidate): Double {
        val width = (minOf(a.right, b.right) - maxOf(a.left, b.left)).coerceAtLeast(0.0)
        val height = (minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)).coerceAtLeast(0.0)
        val intersection = width * height
        val union = (a.right - a.left) * (a.bottom - a.top) +
            (b.right - b.left) * (b.bottom - b.top) - intersection
        return if (union <= 0.0) 0.0 else intersection / union
    }

    private fun createRetinaPriors(): List<RetinaPrior> {
        val priors = ArrayList<RetinaPrior>(16800)
        val steps = intArrayOf(8, 16, 32)
        val minSizes = arrayOf(intArrayOf(16, 32), intArrayOf(64, 128), intArrayOf(256, 512))
        for (level in steps.indices) {
            val step = steps[level]
            val featureSize = (640 + step - 1) / step
            for (y in 0 until featureSize) for (x in 0 until featureSize) {
                for (minSize in minSizes[level]) {
                    priors += RetinaPrior(
                        centerX = (x + 0.5f) * step / 640f,
                        centerY = (y + 0.5f) * step / 640f,
                        width = minSize / 640f,
                        height = minSize / 640f,
                    )
                }
            }
        }
        return priors
    }

    private fun closeTfliteSession(native: NativeTfliteSession) = synchronized(native) {
        if (!native.closed) {
            native.closed = true
            try { native.interpreter.close() } finally {
                native.gpuDelegate?.close()
                native.inputBuffer.clear()
                native.outputBuffers.forEach { it.clear() }
            }
        }
    }

    /**
     * Owns Android's preview, CameraX analyzer and the persistent GPU session.
     * The full 640x640 buffer deliberately never crosses a Flutter channel.
     * Only decoded face geometry, an 80x80 liveness crop, or a final JPEG may
     * cross the process boundary.
     */
    private inner class NativeFaceCamera(renderer: FlutterRenderer) {
        private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "wrytte-native-retina").apply { isDaemon = true }
        }
        private val running = AtomicBoolean(false)
        private val texture: TextureRegistry.SurfaceTextureEntry = renderer.createSurfaceTexture()
        val textureId: Long get() = texture.id()
        private val previewSurface: Surface = Surface(texture.surfaceTexture())
        private var provider: ProcessCameraProvider? = null
        private var sessionId: String? = null
        private var nextFrameId = 0
        private val retained = LinkedHashMap<Int, ByteArray>()

        fun start() {
            if (!running.compareAndSet(false, true)) return
            executor.execute {
                try {
                    if (sessionId == null) {
                        val native = createTfliteRetinaFaceSession(
                            materializeFlutterAsset("assets/models/retinaface_mv2.tflite"), 4,
                        )
                        val id = UUID.randomUUID().toString()
                        tfliteSessions[id] = native
                        sessionId = id
                        Log.i("WrytteLiteRT", "Native CameraX RetinaFace session ready provider=${native.executionProvider}")
                    }
                    bindCamera()
                } catch (error: Throwable) {
                    emit(mapOf("type" to "error", "error" to (error.message ?: "native camera startup failed")))
                    Log.e("WrytteLiteRT", "Native CameraX scanner start failed", error)
                }
            }
        }

        private fun bindCamera() {
            val future = ProcessCameraProvider.getInstance(this@MainActivity)
            future.addListener({
                try {
                    val cameraProvider = future.get()
                    provider = cameraProvider
                    val preview = Preview.Builder().build().also { useCase ->
                        useCase.setSurfaceProvider { request ->
                            // CameraX owns the negotiated buffer dimensions.
                            // Hard-coding a portrait size stretched the Flutter
                            // texture and caused visible blue surface artefacts.
                            texture.surfaceTexture().setDefaultBufferSize(
                                request.resolution.width,
                                request.resolution.height,
                            )
                            request.provideSurface(previewSurface, executor) { }
                        }
                    }
                    val analysis = ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                        .build()
                    analysis.setAnalyzer(executor) { image -> analyze(image) }
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        this@MainActivity as LifecycleOwner,
                        CameraSelector.DEFAULT_FRONT_CAMERA,
                        preview,
                        analysis,
                    )
                    Log.i("WrytteLiteRT", "Native CameraX preview and analyzer bound")
                    emit(mapOf("type" to "ready"))
                } catch (error: Throwable) {
                    emit(mapOf("type" to "error", "error" to (error.message ?: "CameraX bind failed")))
                    Log.e("WrytteLiteRT", "Native CameraX bind failed", error)
                }
            }, ContextCompat.getMainExecutor(this@MainActivity))
        }

        private fun analyze(image: ImageProxy) {
            try {
                if (!running.get()) return
                val id = sessionId ?: return
                val packed = imageToCenteredBgr(image)
                val infer = packed.copyOf()
                val result = runTfliteRetinaBgr(
                    mapOf("sessionId" to id, "bgr" to infer, "width" to 640, "height" to 640),
                )
                val faces = result["faces"] as List<*>
                if (faces.isNotEmpty()) {
                    val frameId = ++nextFrameId
                    synchronized(retained) {
                        retained[frameId] = packed
                        while (retained.size > 3) retained.remove(retained.entries.first().key)?.fill(0)
                    }
                    emit(mapOf("type" to "frame", "frameId" to frameId, "faces" to faces))
                } else {
                    packed.fill(0)
                    emit(mapOf("type" to "frame", "frameId" to -1, "faces" to emptyList<Map<String, Any>>()))
                }
            } catch (error: Throwable) {
                Log.e("WrytteLiteRT", "Native CameraX RetinaFace frame failed", error)
                emit(mapOf("type" to "error", "error" to (error.message ?: "native RetinaFace frame failed")))
            } finally {
                image.close()
            }
        }

        // ImageAnalysis RGBA output is read directly with its row stride;
        // this is the former Dart conversion plus 640 crop, but entirely
        // native and immediately adjacent to the GPU interpreter.
        private fun imageToCenteredBgr(image: ImageProxy): ByteArray {
            val plane = image.planes[0]
            val input = plane.buffer.duplicate()
            val stride = plane.rowStride
            val width = image.width
            val height = image.height
            val side = minOf(width, height)
            val offsetX = (width - side) / 2
            val offsetY = (height - side) / 2
            val bgr = ByteArray(640 * 640 * 3)
            for (y in 0 until 640) {
                val sourceY = offsetY + (y * side / 640).coerceAtMost(side - 1)
                for (x in 0 until 640) {
                    val sourceX = offsetX + (x * side / 640).coerceAtMost(side - 1)
                    val source = sourceY * stride + sourceX * 4
                    val target = (y * 640 + x) * 3
                    bgr[target] = input.get(source + 2)
                    bgr[target + 1] = input.get(source + 1)
                    bgr[target + 2] = input.get(source)
                }
            }
            return bgr
        }

        fun livenessCrop(arguments: Map<*, *>, result: MethodChannel.Result) {
            executor.execute {
                try {
                    val frameId = (arguments["frameId"] as Number).toInt()
                    val bytes = synchronized(retained) { retained[frameId]?.copyOf() }
                        ?: error("Native RetinaFace frame has expired")
                    val left = (arguments["left"] as Number).toDouble()
                    val top = (arguments["top"] as Number).toDouble()
                    val right = (arguments["right"] as Number).toDouble()
                    val bottom = (arguments["bottom"] as Number).toDouble()
                    val crop = cropLiveness(bytes, left, top, right, bottom)
                    bytes.fill(0)
                    runOnUiThread { result.success(mapOf("crop" to crop, "width" to 640, "height" to 640)) }
                } catch (error: Throwable) {
                    runOnUiThread { result.error("NATIVE_CAMERA_ERROR", error.message, error.stackTraceToString()) }
                }
            }
        }

        fun takeJpeg(arguments: Map<*, *>, result: MethodChannel.Result) {
            executor.execute {
                try {
                    val frameId = (arguments["frameId"] as Number).toInt()
                    val bgr = synchronized(retained) { retained.remove(frameId) }
                        ?: error("Native RetinaFace frame has expired")
                    val jpeg = bgrToJpeg(bgr)
                    bgr.fill(0)
                    runOnUiThread { result.success(jpeg) }
                } catch (error: Throwable) {
                    runOnUiThread { result.error("NATIVE_CAMERA_ERROR", error.message, error.stackTraceToString()) }
                }
            }
        }

        fun discard(frameId: Int) {
            executor.execute { synchronized(retained) { retained.remove(frameId)?.fill(0) } }
        }

        private fun cropLiveness(bgr: ByteArray, left: Double, top: Double, right: Double, bottom: Double): ByteArray {
            val faceWidth = (right - left).coerceAtLeast(1.0)
            val faceHeight = (bottom - top).coerceAtLeast(1.0)
            val scale = minOf(2.7, minOf(639.0 / faceWidth, 639.0 / faceHeight))
            val cropWidth = (faceWidth * scale).toInt().coerceAtLeast(1)
            val cropHeight = (faceHeight * scale).toInt().coerceAtLeast(1)
            var cropLeft = (left + faceWidth / 2 - cropWidth / 2).toInt()
            var cropTop = (top + faceHeight / 2 - cropHeight / 2).toInt()
            cropLeft = cropLeft.coerceIn(0, 640 - cropWidth)
            cropTop = cropTop.coerceIn(0, 640 - cropHeight)
            val output = ByteArray(80 * 80 * 3)
            for (y in 0 until 80) for (x in 0 until 80) {
                val sx = cropLeft + (x * cropWidth / 80).coerceAtMost(cropWidth - 1)
                val sy = cropTop + (y * cropHeight / 80).coerceAtMost(cropHeight - 1)
                val source = (sy * 640 + sx) * 3
                val target = (y * 80 + x) * 3
                output[target] = bgr[source]
                output[target + 1] = bgr[source + 1]
                output[target + 2] = bgr[source + 2]
            }
            return output
        }

        private fun bgrToJpeg(bgr: ByteArray): ByteArray {
            val pixels = IntArray(640 * 640)
            for (index in pixels.indices) {
                val source = index * 3
                val b = bgr[source].toInt() and 0xff
                val g = bgr[source + 1].toInt() and 0xff
                val r = bgr[source + 2].toInt() and 0xff
                pixels[index] = 0xff000000.toInt() or (r shl 16) or (g shl 8) or b
            }
            val bitmap = Bitmap.createBitmap(pixels, 640, 640, Bitmap.Config.ARGB_8888)
            return try {
                ByteArrayOutputStream().use { stream ->
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream))
                    stream.toByteArray()
                }
            } finally { bitmap.recycle(); pixels.fill(0) }
        }

        fun reset() {
            synchronized(retained) { retained.values.forEach { it.fill(0) }; retained.clear() }
            if (!running.get()) start()
        }
        fun stop() { running.set(false); provider?.unbindAll(); reset() }
        fun destroy() {
            stop()
            sessionId?.let { tfliteSessions.remove(it)?.let(::closeTfliteSession) }
            previewSurface.release()
            texture.release()
            executor.shutdownNow()
        }
        private fun emit(event: Map<String, Any>) { runOnUiThread { nativeFaceEventSink?.success(event) } }
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
        nativeFaceCamera?.destroy()
        nativeFaceCamera = null
        tfliteSessions.values.forEach { closeTfliteSession(it) }
        tfliteSessions.clear()
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
