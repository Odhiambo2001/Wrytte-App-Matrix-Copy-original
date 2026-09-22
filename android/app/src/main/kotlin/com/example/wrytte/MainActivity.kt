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
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.telephony.TelephonyManager
import androidx.camera.core.ImageProxy
import androidx.core.view.WindowCompat
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.camerax.NativeBiometricAnalyzerRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
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
    private val nativeBiometricStreamChannel = "com.example.wrytte/native_biometric_stream"
    private val nativeBiometricStreamEventsChannel = "com.example.wrytte/native_biometric_stream/events"
    private val cameraCapabilitiesChannel = "com.example.wrytte/camera_capabilities"
    private var callerRingback: ToneGenerator? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ortEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private val ortSessions = ConcurrentHashMap<String, NativeOrtSession>()
    private val tfliteSessions = ConcurrentHashMap<String, NativeTfliteSession>()
    private var nativeEventSink: EventChannel.EventSink? = null
    private var nativeAnalyzerExecutor: ExecutorService? = null
    private var nativeAnalyzerSession: NativeTfliteSession? = null
    private val nativeAnalyzerEnabled = AtomicBoolean(false)
    private val nativeAnalyzerBusy = AtomicBoolean(false)
    private var nativeFrameIndex = 0L
    // Bounds how many accepted (target != null) frames the native analyzer
    // will emit before self-disabling. Set from Dart's "start" call so the
    // analyzer stops itself on the same thread that decided a frame
    // qualifies, instead of waiting for a "stop" MethodChannel round trip.
    private var nativeAnalyzerMaxTargets = Int.MAX_VALUE
    private var nativeAnalyzerTargetCount = 0
    // A prewarmed session is built on the same serial LiteRT queue that later
    // owns inference. It is leased by createRetinaFaceSession, rather than
    // compiled again when the scan page opens.
    private val prewarmedTfliteSessions = ConcurrentHashMap<String, NativeTfliteSession>()

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
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            nativeBiometricStreamEventsChannel,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                nativeEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                nativeEventSink = null
            }
        })
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            nativeBiometricStreamChannel,
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        val asset = requireNotNull(call.argument<String>("asset"))
                        val threads = (call.argument<Int>("threads") ?: 4)
                            .coerceAtLeast(1)
                            .coerceAtMost(Runtime.getRuntime().availableProcessors().coerceAtLeast(1))
                        val maxTargets = call.argument<Int>("maxTargets") ?: Int.MAX_VALUE
                        startNativeBiometricAnalyzer(asset, threads, maxTargets)
                        result.success(null)
                    }
                    "stop" -> {
                        stopNativeBiometricAnalyzer()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Throwable) {
                result.error("NATIVE_BIOMETRIC_STREAM_ERROR", error.message, error.stackTraceToString())
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
                    "prewarmRetinaFace" -> {
                        val asset = requireNotNull(call.argument<String>("asset"))
                        val threads = (call.argument<Int>("threads") ?: 4)
                            .coerceAtLeast(1)
                            .coerceAtMost(Runtime.getRuntime().availableProcessors().coerceAtLeast(1))
                        if (prewarmedTfliteSessions[asset] == null) {
                            val native = createTfliteRetinaFaceSession(
                                mapFlutterAsset(asset),
                                threads,
                            )
                            val previous = prewarmedTfliteSessions.putIfAbsent(asset, native)
                            if (previous != null) closeTfliteSession(native)
                            Log.i("WrytteLiteRT", "RetinaFace LiteRT prewarm completed")
                        }
                        result.success(null)
                    }
                    "createRetinaFaceSession" -> {
                        val asset = requireNotNull(call.argument<String>("asset"))
                        val threads = (call.argument<Int>("threads") ?: 4)
                            .coerceAtLeast(1)
                            .coerceAtMost(Runtime.getRuntime().availableProcessors().coerceAtLeast(1))
                        val native = prewarmedTfliteSessions.remove(asset)
                            ?: createTfliteRetinaFaceSession(mapFlutterAsset(asset), threads)
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
     * Maps an uncompressed Flutter LiteRT asset directly from the APK. If an
     * older build tool compresses it despite androidResources.noCompress, the
     * cache-file fallback is still memory-mapped and remains correct.
     */
    private fun mapFlutterAsset(asset: String): ByteBuffer {
        val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
        try {
            assets.openFd(key).use { descriptor ->
                FileInputStream(descriptor.fileDescriptor).channel.use { channel ->
                    return channel.map(
                        java.nio.channels.FileChannel.MapMode.READ_ONLY,
                        descriptor.startOffset,
                        descriptor.length,
                    ).order(ByteOrder.nativeOrder())
                }
            }
        } catch (error: Throwable) {
            Log.w(
                "WrytteLiteRT",
                "RetinaFace APK asset is not directly mappable; using mapped cache fallback: ${error.message}",
            )
            val file = materializeFlutterAsset(asset)
            FileInputStream(file).channel.use { channel ->
                return channel.map(
                    java.nio.channels.FileChannel.MapMode.READ_ONLY,
                    0,
                    channel.size(),
                ).order(ByteOrder.nativeOrder())
            }
        }
    }

    /**
     * Creates a LiteRT RetinaFace interpreter with the GPU delegate when the
     * device reports GPU support. If GPU setup is unavailable, retain a CPU
     * interpreter as the device-compatibility fallback. The app logs the
     * selected provider for every detector initialization.
     */
    private fun createTfliteRetinaFaceSession(model: ByteBuffer, threads: Int): NativeTfliteSession {
        val compatibility = CompatibilityList()
        var gpuDelegate: GpuDelegate? = null
        var provider = "cpu"
        val options = Interpreter.Options()
        try {
            if (compatibility.isDelegateSupportedOnThisDevice) {
                // Use the device-specific GPU options selected by LiteRT. The
                // delegate and interpreter are retained for the whole scan;
                // neither is recreated for an individual camera frame.
                val gpuOptions = compatibility.bestOptionsForThisDevice
                configureGpuDelegateSerialization(gpuOptions)
                gpuDelegate = GpuDelegate(gpuOptions)
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

    /**
     * LiteRT exposes GPU serialization through the Java API only in selected
     * releases. Reflection keeps this APK compatible with 2.16.1 while
     * enabling the on-disk delegate cache automatically when that API exists.
     */
    private fun configureGpuDelegateSerialization(options: GpuDelegate.Options) {
        try {
            val method = options.javaClass.methods.firstOrNull {
                it.name == "setSerializationParams" && it.parameterTypes.size == 2
            } ?: run {
                Log.i("WrytteLiteRT", "GPU delegate serialization API unavailable in this LiteRT build")
                return
            }
            val directory = File(codeCacheDir, "retinaface_gpu_cache").apply { mkdirs() }
            method.invoke(options, directory.absolutePath, "retinaface_mv2_v1")
            Log.i("WrytteLiteRT", "GPU delegate persistent cache enabled dir=${directory.name}")
        } catch (error: Throwable) {
            Log.w("WrytteLiteRT", "GPU delegate cache unavailable: ${error.message}")
        }
    }

    private fun startNativeBiometricAnalyzer(asset: String, threads: Int, maxTargets: Int) {
        if (nativeAnalyzerEnabled.get()) return
        nativeAnalyzerEnabled.set(true)
        nativeAnalyzerTargetCount = 0
        nativeAnalyzerMaxTargets = maxTargets
        val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "wrytte-native-biometric-analyzer")
        }
        nativeAnalyzerExecutor = executor
        NativeBiometricAnalyzerRegistry.setAnalyzer { image ->
            if (!nativeAnalyzerEnabled.get()) return@setAnalyzer false
            if (!nativeAnalyzerBusy.compareAndSet(false, true)) {
                image.close()
                return@setAnalyzer true
            }
            executor.execute {
                try {
                    val session = nativeAnalyzerSession
                        ?: (prewarmedTfliteSessions.remove(asset)
                            ?: createTfliteRetinaFaceSession(
                                mapFlutterAsset(asset),
                                threads,
                            )).also { nativeAnalyzerSession = it }
                    analyzeNativeBiometricFrame(session, image)
                } catch (error: Throwable) {
                    Log.e(
                        "WrytteNativeBio",
                        "Native biometric frame failed: ${error.javaClass.simpleName}: ${error.message}",
                        error,
                    )
                } finally {
                    try { image.close() } catch (_: Throwable) {}
                    nativeAnalyzerBusy.set(false)
                }
            }
            true
        }
        Log.i("WrytteNativeBio", "Native CameraX biometric analyzer enabled")
    }

    private fun stopNativeBiometricAnalyzer() {
        nativeAnalyzerEnabled.set(false)
        NativeBiometricAnalyzerRegistry.setAnalyzer(null)
        nativeAnalyzerBusy.set(false)
        val executor = nativeAnalyzerExecutor
        nativeAnalyzerExecutor = null
        executor?.execute {
            nativeAnalyzerSession?.let { closeTfliteSession(it) }
            nativeAnalyzerSession = null
        }
        executor?.shutdown()
        Log.i("WrytteNativeBio", "Native CameraX biometric analyzer disabled")
    }

    private fun analyzeNativeBiometricFrame(native: NativeTfliteSession, image: ImageProxy) {
        val startedAt = SystemClock.elapsedRealtimeNanos()
        val result = runTfliteRetinaImageDirect(native, image)
        val faces = result.faces.map { faceMapToDetection(it) }
        val target = chooseNativeTarget(faces)
        val elapsedMs = ((SystemClock.elapsedRealtimeNanos() - startedAt) / 1_000_000.0).toLong()
        val index = nativeFrameIndex++
        // Self-stop the instant this frame reaches the target count. This
        // runs on the same worker thread that just decided the frame
        // qualifies, so no further frames are admitted while a "stop"
        // MethodChannel call from Dart is still in flight.
        if (target != null) {
            nativeAnalyzerTargetCount++
            if (nativeAnalyzerTargetCount >= nativeAnalyzerMaxTargets) {
                nativeAnalyzerEnabled.set(false)
                NativeBiometricAnalyzerRegistry.setAnalyzer(null)
            }
        }
        val event = HashMap<String, Any?>()
        event["index"] = index
        event["width"] = 640
        event["height"] = 640
        event["faceDetected"] = faces.isNotEmpty()
        event["targetFaceSelected"] = target != null
        event["alignmentAccepted"] = target != null
        event["processingMilliseconds"] = elapsedMs
        event["multipleFaces"] = faces.size > 1
        event["faceTooFar"] = faces.isNotEmpty() && faces.all { measureNativeFaceDistance(it) == "FAR" }
        event["faceTooClose"] = faces.isNotEmpty() && faces.all { measureNativeFaceDistance(it) == "CLOSE" }
        target?.let {
            val bgr = imageProxyToCenteredRetinaBgr(image)
            event["faceCenterX"] = (it.left + it.right) / 2.0
            event["faceCenterY"] = (it.top + it.bottom) / 2.0
            event["target"] = it.raw
            event["source"] = bgr
            event["jpeg"] = retinaBgrToJpeg(bgr)
        }
        mainHandler.post { nativeEventSink?.success(event) }
        Log.i(
            "WrytteNativeBio",
            "frame=$index faces=${faces.size} target=${target != null} native_stream=active " +
                "direct_imageproxy_to_litert=active " +
                "elapsed_ms=$elapsedMs provider=${native.executionProvider}",
        )
    }

    private fun runTfliteRetinaImageDirect(
        native: NativeTfliteSession,
        image: ImageProxy,
    ): TfliteRetinaRunResult {
        return synchronized(native) {
            check(!native.closed) { "Session is closed" }
            try {
                val frameStartedAt = SystemClock.elapsedRealtimeNanos()
                native.inputBuffer.clear()
                val floats = native.inputBuffer.asFloatBuffer()
                writeImageProxyToRetinaInput(image, floats)
                native.inputBuffer.position(0)
                val preprocessingMs =
                    (SystemClock.elapsedRealtimeNanos() - frameStartedAt) / 1_000_000.0
                invokePreparedTfliteRetina(native, frameStartedAt, preprocessingMs)
            } finally {
                wipeTfliteIoBuffers(native)
            }
        }
    }

    private fun writeImageProxyToRetinaInput(image: ImageProxy, floats: FloatBuffer) {
        val width = image.width
        val height = image.height
        val rotation = image.imageInfo.rotationDegrees
        val mapping = createRetinaSourceMapping(width, height, rotation)
        val planes = image.planes
        val yPlane = planes[0]
        val uPlane = planes[1]
        val vPlane = planes[2]
        val y = yPlane.buffer.duplicate()
        val u = uPlane.buffer.duplicate()
        val v = vPlane.buffer.duplicate()
        val yRowStride = yPlane.rowStride
        val uRowStride = uPlane.rowStride
        val vRowStride = vPlane.rowStride
        val uPixelStride = uPlane.pixelStride
        val vPixelStride = vPlane.pixelStride
        for (outY in 0 until 640) {
            val rowSourceColumn = mapping.rowSourceColumns[outY]
            val rowSourceRow = mapping.rowSourceRows[outY]
            for (outX in 0 until 640) {
                val sourceColumn =
                    if (rowSourceColumn >= 0) rowSourceColumn else mapping.columnSourceColumns[outX]
                val sourceRow =
                    if (rowSourceRow >= 0) rowSourceRow else mapping.columnSourceRows[outX]
                val yBase = sourceRow * yRowStride
                val uvY = sourceRow shr 1
                val uBase = uvY * uRowStride
                val vBase = uvY * vRowStride
                val yValue = y.get(yBase + sourceColumn).toInt() and 0xff
                val uvX = sourceColumn shr 1
                val uValue = u.get(uBase + uvX * uPixelStride).toInt() and 0xff
                val vValue = v.get(vBase + uvX * vPixelStride).toInt() and 0xff
                val c = yValue - 16
                val d = uValue - 128
                val e = vValue - 128
                val red = ((298 * c + 409 * e + 128) shr 8).coerceIn(0, 255)
                val green = ((298 * c - 100 * d - 208 * e + 128) shr 8).coerceIn(0, 255)
                val blue = ((298 * c + 516 * d + 128) shr 8).coerceIn(0, 255)
                floats.put(blue - 104f)
                floats.put(green - 117f)
                floats.put(red - 123f)
            }
        }
    }

    private fun imageProxyToCenteredRetinaBgr(image: ImageProxy): ByteArray {
        val width = image.width
        val height = image.height
        val rotation = image.imageInfo.rotationDegrees
        val mapping = createRetinaSourceMapping(width, height, rotation)
        val planes = image.planes
        val yPlane = planes[0]
        val uPlane = planes[1]
        val vPlane = planes[2]
        val y = yPlane.buffer.duplicate()
        val u = uPlane.buffer.duplicate()
        val v = vPlane.buffer.duplicate()
        val yRowStride = yPlane.rowStride
        val uRowStride = uPlane.rowStride
        val vRowStride = vPlane.rowStride
        val uPixelStride = uPlane.pixelStride
        val vPixelStride = vPlane.pixelStride
        val out = ByteArray(640 * 640 * 3)
        var offset = 0
        for (outY in 0 until 640) {
            val rowSourceColumn = mapping.rowSourceColumns[outY]
            val rowSourceRow = mapping.rowSourceRows[outY]
            for (outX in 0 until 640) {
                val sourceColumn =
                    if (rowSourceColumn >= 0) rowSourceColumn else mapping.columnSourceColumns[outX]
                val sourceRow =
                    if (rowSourceRow >= 0) rowSourceRow else mapping.columnSourceRows[outX]
                val yBase = sourceRow * yRowStride
                val uvY = sourceRow shr 1
                val uBase = uvY * uRowStride
                val vBase = uvY * vRowStride
                val yValue = y.get(yBase + sourceColumn).toInt() and 0xff
                val uvX = sourceColumn shr 1
                val uValue = u.get(uBase + uvX * uPixelStride).toInt() and 0xff
                val vValue = v.get(vBase + uvX * vPixelStride).toInt() and 0xff
                val c = yValue - 16
                val d = uValue - 128
                val e = vValue - 128
                out[offset++] = ((298 * c + 516 * d + 128) shr 8)
                    .coerceIn(0, 255)
                    .toByte()
                out[offset++] = ((298 * c - 100 * d - 208 * e + 128) shr 8)
                    .coerceIn(0, 255)
                    .toByte()
                out[offset++] = ((298 * c + 409 * e + 128) shr 8)
                    .coerceIn(0, 255)
                    .toByte()
            }
        }
        return out
    }

    private fun retinaBgrToJpeg(bgr: ByteArray): ByteArray {
        val pixels = IntArray(640 * 640)
        var source = 0
        for (index in pixels.indices) {
            val blue = bgr[source++].toInt() and 0xff
            val green = bgr[source++].toInt() and 0xff
            val red = bgr[source++].toInt() and 0xff
            pixels[index] = (0xff shl 24) or (red shl 16) or (green shl 8) or blue
        }
        val bitmap = Bitmap.createBitmap(pixels, 640, 640, Bitmap.Config.ARGB_8888)
        return try {
            ByteArrayOutputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 70, output)
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private data class RetinaSourceMapping(
        val columnSourceColumns: IntArray,
        val columnSourceRows: IntArray,
        val rowSourceColumns: IntArray,
        val rowSourceRows: IntArray,
    )

    private fun createRetinaSourceMapping(
        width: Int,
        height: Int,
        rotation: Int,
    ): RetinaSourceMapping {
        val rotatedWidth = if (rotation == 90 || rotation == 270) height else width
        val rotatedHeight = if (rotation == 90 || rotation == 270) width else height
        val cropSide = minOf(rotatedWidth, rotatedHeight)
        val cropLeft = (rotatedWidth - cropSide) / 2
        val cropTop = (rotatedHeight - cropSide) / 2
        val rotatedX = IntArray(640)
        val rotatedY = IntArray(640)
        for (index in 0 until 640) {
            rotatedX[index] = (cropLeft + ((index + 0.5) * cropSide / 640.0)
                .toInt()
                .coerceIn(0, cropSide - 1))
                .coerceIn(0, rotatedWidth - 1)
            rotatedY[index] = (cropTop + ((index + 0.5) * cropSide / 640.0)
                .toInt()
                .coerceIn(0, cropSide - 1))
                .coerceIn(0, rotatedHeight - 1)
        }
        val columnSourceColumns = IntArray(640)
        val columnSourceRows = IntArray(640)
        val rowSourceColumns = IntArray(640)
        val rowSourceRows = IntArray(640)
        for (index in 0 until 640) {
            when (rotation) {
                90 -> {
                    columnSourceColumns[index] = -1
                    columnSourceRows[index] = (height - 1 - rotatedX[index]).coerceIn(0, height - 1)
                    rowSourceColumns[index] = rotatedY[index].coerceIn(0, width - 1)
                    rowSourceRows[index] = -1
                }
                180 -> {
                    columnSourceColumns[index] = (width - 1 - rotatedX[index]).coerceIn(0, width - 1)
                    columnSourceRows[index] = -1
                    rowSourceColumns[index] = -1
                    rowSourceRows[index] = (height - 1 - rotatedY[index]).coerceIn(0, height - 1)
                }
                270 -> {
                    columnSourceColumns[index] = -1
                    columnSourceRows[index] = rotatedX[index].coerceIn(0, height - 1)
                    rowSourceColumns[index] = (width - 1 - rotatedY[index]).coerceIn(0, width - 1)
                    rowSourceRows[index] = -1
                }
                else -> {
                    columnSourceColumns[index] = rotatedX[index].coerceIn(0, width - 1)
                    columnSourceRows[index] = -1
                    rowSourceColumns[index] = -1
                    rowSourceRows[index] = rotatedY[index].coerceIn(0, height - 1)
                }
            }
        }
        return RetinaSourceMapping(
            columnSourceColumns = columnSourceColumns,
            columnSourceRows = columnSourceRows,
            rowSourceColumns = rowSourceColumns,
            rowSourceRows = rowSourceRows,
        )
    }

    private data class NativeFace(val raw: Map<String, Any>, val left: Double, val top: Double, val right: Double, val bottom: Double, val confidence: Double)

    private fun faceMapToDetection(raw: Map<String, Any>): NativeFace {
        return NativeFace(
            raw = raw,
            left = (raw["left"] as Number).toDouble(),
            top = (raw["top"] as Number).toDouble(),
            right = (raw["right"] as Number).toDouble(),
            bottom = (raw["bottom"] as Number).toDouble(),
            confidence = (raw["confidence"] as Number).toDouble(),
        )
    }

    private fun measureNativeFaceDistance(face: NativeFace): String {
        val size = maxOf((face.right - face.left) / 640.0, (face.bottom - face.top) / 640.0)
        return when {
            size < 0.34 -> "FAR"
            size > 0.72 -> "CLOSE"
            else -> "NORMAL"
        }
    }

    private fun chooseNativeTarget(faces: List<NativeFace>): NativeFace? {
        if (faces.isEmpty() || faces.size > 2) return null
        val qualifying = faces.filter { face ->
            face.confidence >= 0.83 &&
                measureNativeFaceDistance(face) == "NORMAL" &&
                visibleNativeFraction(face) >= 0.90
        }
        if (qualifying.size == 1 && faces.size == 1) return qualifying.first()
        if (qualifying.size == 1 && faces.size == 2) {
            val other = faces.first { it !== qualifying.first() }
            val gap = nativeSizeRatio(qualifying.first()) - nativeSizeRatio(other)
            if (measureNativeFaceDistance(other) == "FAR" && gap >= 0.20) return qualifying.first()
        }
        return null
    }

    private fun nativeSizeRatio(face: NativeFace): Double =
        maxOf((face.right - face.left) / 640.0, (face.bottom - face.top) / 640.0)

    private fun visibleNativeFraction(face: NativeFace): Double {
        val left = ((face.raw["rawLeft"] as? Number)?.toDouble()) ?: face.left
        val top = ((face.raw["rawTop"] as? Number)?.toDouble()) ?: face.top
        val right = ((face.raw["rawRight"] as? Number)?.toDouble()) ?: face.right
        val bottom = ((face.raw["rawBottom"] as? Number)?.toDouble()) ?: face.bottom
        val full = maxOf(0.0, right - left) * maxOf(0.0, bottom - top)
        if (full <= 0.0) return 0.0
        val visible = maxOf(0.0, minOf(640.0, right) - maxOf(0.0, left)) *
            maxOf(0.0, minOf(640.0, bottom) - maxOf(0.0, top))
        return visible / full
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
        val decoded = runTfliteRetinaBgrDirect(native, bytes)
        bytes.fill(0)
        return mapOf(
            "faces" to decoded.faces,
            "executionProvider" to native.executionProvider,
            "nativeTotalMs" to decoded.totalMs,
            "invokeMs" to decoded.invokeMs,
        )
    }

    private data class TfliteRetinaRunResult(
        val faces: List<Map<String, Any>>,
        val totalMs: Double,
        val invokeMs: Double,
    )

    private fun runTfliteRetinaBgrDirect(native: NativeTfliteSession, bytes: ByteArray): TfliteRetinaRunResult {
        return synchronized(native) {
            check(!native.closed) { "Session is closed" }
            try {
                val frameStartedAt = SystemClock.elapsedRealtimeNanos()
                // Converted LiteRT input is NHWC, but its channels preserve
                // ONNX RetinaFace's B/G/R mean-subtracted semantics.
                native.inputBuffer.clear()
                val floats = native.inputBuffer.asFloatBuffer()
                for (pixel in 0 until 640 * 640) {
                    val offset = pixel * 3
                    floats.put((bytes[offset].toInt() and 0xff) - 104f)
                    floats.put((bytes[offset + 1].toInt() and 0xff) - 117f)
                    floats.put((bytes[offset + 2].toInt() and 0xff) - 123f)
                }
                native.inputBuffer.position(0)
                val preprocessingMs =
                    (SystemClock.elapsedRealtimeNanos() - frameStartedAt) / 1_000_000.0
                invokePreparedTfliteRetina(native, frameStartedAt, preprocessingMs)
            } finally {
                wipeTfliteIoBuffers(native)
            }
        }
    }

    private fun invokePreparedTfliteRetina(
        native: NativeTfliteSession,
        frameStartedAt: Long,
        preprocessingMs: Double,
    ): TfliteRetinaRunResult {
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
        return TfliteRetinaRunResult(decoded.faces, totalMs, invokeMs)
    }

    private fun wipeTfliteIoBuffers(native: NativeTfliteSession) {
        native.inputBuffer.clear()
        while (native.inputBuffer.hasRemaining()) native.inputBuffer.put(0.toByte())
        native.inputBuffer.clear()
        native.outputBuffers.forEach { buffer ->
            buffer.clear()
            while (buffer.hasRemaining()) buffer.put(0.toByte())
            buffer.clear()
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
