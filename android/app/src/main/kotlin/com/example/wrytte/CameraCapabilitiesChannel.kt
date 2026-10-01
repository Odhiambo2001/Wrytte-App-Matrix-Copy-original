package com.example.wrytte

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan2

/** Best-effort metadata absent from Flutter's public camera API. */
class CameraCapabilitiesChannel(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "wrytte/camera_capabilities")
    private val cameraManager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getCameraCapabilities") {
            result.notImplemented()
            return
        }
        try {
            val snapshots = cameraManager.cameraIdList.mapNotNull(::readSnapshot)
            val defaults = snapshots.groupBy { it.lensFacing }.mapValues { (_, cameras) ->
                cameras.firstOrNull { it.backwardCompatible } ?: cameras.first()
            }
            result.success(snapshots.map { camera ->
                mapOf(
                    "cameraId" to camera.id,
                    "intrinsicZoomRatio" to intrinsicZoom(camera, defaults[camera.lensFacing]),
                    "logicalMultiCamera" to camera.logicalMultiCamera,
                    "physicalCameraIds" to camera.physicalCameraIds,
                    "flashAvailable" to camera.flashAvailable,
                )
            })
        } catch (error: Throwable) {
            result.error("camera_capabilities_failed", error.message ?: error.toString(), null)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private fun readSnapshot(id: String): Snapshot? = try {
        val characteristics = cameraManager.getCameraCharacteristics(id)
        val facing = characteristics.get(CameraCharacteristics.LENS_FACING) ?: return null
        val capabilities = characteristics.get(
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES,
        ) ?: intArrayOf()
        val logical = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            capabilities.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)
        Snapshot(
            id = id,
            lensFacing = facing,
            backwardCompatible = capabilities.contains(
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE,
            ),
            logicalMultiCamera = logical,
            physicalCameraIds = if (logical && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                characteristics.physicalCameraIds.toList()
            } else {
                emptyList()
            },
            fieldOfViewRadians = horizontalFieldOfView(characteristics),
            flashAvailable = characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true,
        )
    } catch (_: Throwable) {
        null
    }

    private fun horizontalFieldOfView(characteristics: CameraCharacteristics): Double? {
        val sensor = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            ?: return null
        val focalLength = characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?.filter { it.isFinite() && it > 0f }
            ?.minOrNull()
            ?: return null
        return 2.0 * atan2(sensor.width.toDouble() / 2.0, focalLength.toDouble())
    }

    private fun intrinsicZoom(camera: Snapshot, default: Snapshot?): Double {
        if (default == null || default.id == camera.id) return 1.0
        val defaultFov = default.fieldOfViewRadians ?: return 1.0
        val cameraFov = camera.fieldOfViewRadians ?: return 1.0
        if (defaultFov <= 0 || cameraFov <= 0) return 1.0
        val ratio = defaultFov / cameraFov
        return if (ratio.isFinite() && ratio > 0) ratio else 1.0
    }

    private data class Snapshot(
        val id: String,
        val lensFacing: Int,
        val backwardCompatible: Boolean,
        val logicalMultiCamera: Boolean,
        val physicalCameraIds: List<String>,
        val fieldOfViewRadians: Double?,
        val flashAvailable: Boolean,
    )
}
