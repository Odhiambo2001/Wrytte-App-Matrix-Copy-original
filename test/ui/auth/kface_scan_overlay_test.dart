import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/ui/auth/kface_scan_overlay.dart';

void main() {
  testWidgets(
    'scan motion never creates accepted progress and resets cleanly',
    (tester) async {
      final boundaryKey = GlobalKey();
      var frameNumber = 0;
      Future<void> show({
        bool ticks = false,
        bool scanning = false,
        double progress = 0,
        bool reduceMotion = false,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: Center(
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: ColoredBox(
                    color: Colors.black,
                    child: SizedBox.square(
                      dimension: 300,
                      child: KFaceScanOverlay(
                        faceDiameter: 260,
                        showTicks: ticks,
                        scanning: scanning,
                        progress: progress,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
      }

      Future<({int green, int cyan})> colors() async =>
          (await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes =
                (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
            // Optional frame exports for comparing the ribbon with reference
            // footage: --dart-define=KFACE_RENDER_DIR=/tmp/kface-frames.
            const renderDirectory = String.fromEnvironment('KFACE_RENDER_DIR');
            if (renderDirectory.isNotEmpty) {
              await Directory(renderDirectory).create(recursive: true);
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$renderDirectory/frame-${frameNumber++}.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            }
            var green = 0;
            var cyan = 0;
            for (var i = 0; i < bytes.lengthInBytes; i += 4) {
              final r = bytes.getUint8(i);
              final g = bytes.getUint8(i + 1);
              final b = bytes.getUint8(i + 2);
              if (g > 60 && g > r * 1.3 && g > b * 1.2) green++;
              if (g > 60 && g > r * 1.2 && b > r * 1.2 && b > g * 0.8) cyan++;
            }
            image.dispose();
            return (green: green, cyan: cyan);
          }))!;

      await show();
      expect(await colors(), (green: 0, cyan: 0));
      await show(ticks: true, scanning: true);
      final scanning = await colors();
      expect(scanning.green, 0);
      // The reference has a broad ribbed sheet, not a single glowing line.
      expect(scanning.cyan, greaterThan(1500));
      await tester.pump(const Duration(seconds: 4));
      final moved = await colors();
      expect(moved.green, 0);
      expect(moved.cyan, isNot(scanning.cyan));

      await show(ticks: true, scanning: true, progress: 0.4);
      final partial = await colors();
      expect(partial.green, greaterThan(0));
      expect(partial.cyan, greaterThan(0));
      await show(ticks: true, progress: 1);
      final completed = await colors();
      expect(completed.green, greaterThan(partial.green));
      expect(completed.cyan, 0);

      await show();
      expect(await colors(), (green: 0, cyan: 0));
      await show(
        ticks: true,
        scanning: true,
        progress: 0.4,
        reduceMotion: true,
      );
      expect((await colors()).cyan, 0);
      expect((await colors()).green, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
