class MediaTrimRange {
  const MediaTrimRange({required this.start, required this.end});

  const MediaTrimRange.full(Duration duration)
    : start = Duration.zero,
      end = duration;

  final Duration start;
  final Duration end;

  Duration get duration => end > start ? end - start : Duration.zero;

  bool isFullDuration(Duration sourceDuration) =>
      start <= Duration.zero && end >= sourceDuration;
}
