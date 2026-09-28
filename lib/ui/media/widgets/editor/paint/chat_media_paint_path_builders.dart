import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

class ChatMediaSquarePathBuilder extends PathBuilderBase {
  ChatMediaSquarePathBuilder({
    required super.item,
    required super.paintEditorConfigs,
    required super.scale,
  });

  @override
  Path build() {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;

    final side = math.min(
      dx.abs(),
      dy.abs(),
    );

    final squareEnd = Offset(
      start.dx +
          (dx < 0 ? -side : side),
      start.dy +
          (dy < 0 ? -side : side),
    );

    final rect = Rect.fromPoints(
      start,
      squareEnd,
    );

    path
      ..reset()
      ..addRect(rect);

    return path;
  }

  @override
  bool hitTest(
    Offset position,
  ) {
    return hitTestFillableObject(
      position,
    );
  }
}

class ChatMediaTrianglePathBuilder extends PathBuilderBase {
  ChatMediaTrianglePathBuilder({
    required super.item,
    required super.paintEditorConfigs,
    required super.scale,
  });

  @override
  Path build() {
    final left = math.min(
      start.dx,
      end.dx,
    );

    final right = math.max(
      start.dx,
      end.dx,
    );

    final top = math.min(
      start.dy,
      end.dy,
    );

    final bottom = math.max(
      start.dy,
      end.dy,
    );

    final centerX =
        (left + right) / 2;

    path
      ..reset()
      ..moveTo(
        centerX,
        top,
      )
      ..lineTo(
        right,
        bottom,
      )
      ..lineTo(
        left,
        bottom,
      )
      ..close();

    return path;
  }

  @override
  bool hitTest(
    Offset position,
  ) {
    return hitTestFillableObject(
      position,
    );
  }
}