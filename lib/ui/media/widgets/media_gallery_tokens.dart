import 'package:flutter/material.dart';

abstract final class MediaGalleryTokens {
  static const double compactExtent = 0.68;
  static const double expandedExtent = 0.94;
  static const double minExtent = 0.12;
  static const double dismissExtent = 0.42;
  static const double gridGap = 2;
  static const double targetTileExtent = 118;
  static const double headerHeight = 66;
  static const double menuMaxWidth = 258;
  static const double menuMaxHeight = 420;
  static const BorderRadius sheetRadius = BorderRadius.vertical(
    top: Radius.circular(34),
  );
  static const Duration openDuration = Duration(milliseconds: 260);
  static const Duration closeDuration = Duration(milliseconds: 200);
  static const Duration menuDuration = Duration(milliseconds: 190);
  static const Duration menuReverseDuration = Duration(milliseconds: 210);
}
