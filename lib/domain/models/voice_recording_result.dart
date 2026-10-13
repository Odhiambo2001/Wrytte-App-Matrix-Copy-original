import 'package:wrytte/domain/models/media_trim_range.dart';

class VoiceRecordingResult {
  const VoiceRecordingResult({
    required this.path,
    required this.duration,
    required this.waveform,
    required this.trimRange,
  });

  final String path;
  final Duration duration;
  final List<double> waveform;
  final MediaTrimRange trimRange;
}
