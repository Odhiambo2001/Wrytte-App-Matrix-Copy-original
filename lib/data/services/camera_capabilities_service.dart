import 'package:flutter/services.dart';
import 'package:wrytte/data/models/camera_device_record.dart';

class CameraCapabilitiesService {
  const CameraCapabilitiesService();

  static const _channel = MethodChannel('wrytte/camera_capabilities');

  Future<Map<String, NativeCameraMetadataRecord>> load() async {
    try {
      final payload = await _channel.invokeListMethod<Object?>(
        'getCameraCapabilities',
      );
      if (payload == null) return const {};

      final result = <String, NativeCameraMetadataRecord>{};
      for (final value in payload) {
        if (value is! Map) continue;
        final map = Map<Object?, Object?>.from(value);
        final id = map['cameraId']?.toString();
        if (id == null || id.isEmpty) continue;
        final rawPhysicalIds = map['physicalCameraIds'];
        result[id] = NativeCameraMetadataRecord(
          cameraId: id,
          intrinsicZoomRatio:
              (map['intrinsicZoomRatio'] as num?)?.toDouble() ?? 1,
          logicalMultiCamera: map['logicalMultiCamera'] == true,
          physicalCameraIds: rawPhysicalIds is List
              ? rawPhysicalIds.map((item) => item.toString()).toList()
              : const [],
          flashAvailable: map['flashAvailable'] == true,
        );
      }
      return result;
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }
}
