import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

enum ChatMediaTextBackgroundStyle { light, dark, transparent }

class ChatMediaTextSession extends ChangeNotifier {
  ChatMediaTextSession({required this.onDiscarded});

  final VoidCallback onDiscarded;
  static const double minFontScale = .45;
  static const double defaultFontScale = 1;
  static const double maxFontScale = 3;

  static const Color darkBackground = Color(0x99000000);

  static const List<String> fontNames = [
    'Roboto',
    'Italic',
    'Serif',
    'Condensed',
    'Mono-serif',
    'Merriweather',
    'Pacifico',
  ];

  static const List<TextStyle> fontPresets = [
    TextStyle(
      fontFamily: WrytteTypography.primaryFontFamily,
      fontWeight: FontWeight.w400,
    ),
    TextStyle(
      fontFamily: WrytteTypography.primaryFontFamily,
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.italic,
    ),
    TextStyle(fontFamily: 'NotoSerif', fontWeight: FontWeight.w400),
    TextStyle(fontFamily: 'RobotoCondensed', fontWeight: FontWeight.w400),
    TextStyle(fontFamily: 'RobotoMono', fontWeight: FontWeight.w400),
    TextStyle(fontFamily: 'Merriweather', fontWeight: FontWeight.w400),
    TextStyle(fontFamily: 'Pacifico', fontWeight: FontWeight.w400),
  ];

  TextEditorState? _editor;
  _TextSessionSnapshot? _initialSnapshot;

  bool _initialStyleScheduled = false;

  TextAlign alignment = TextAlign.center;

  ChatMediaTextBackgroundStyle backgroundStyle =
      ChatMediaTextBackgroundStyle.light;

  double fontScale = defaultFontScale;

  int fontIndex = 0;

  bool emojiVisible = false;
  bool busy = false;

  void attach(TextEditorState editor) {
    if (identical(_editor, editor)) {
      return;
    }

    _editor = editor;

    alignment = editor.align;

    fontScale = editor.fontScale.clamp(minFontScale, maxFontScale).toDouble();

    fontIndex = _findFontIndex(editor.selectedTextStyle);

    backgroundStyle = _backgroundStyleFromEditor(editor);

    emojiVisible = false;
    busy = false;

    // Existing text is being edited. Preserve its real state.
    if (editor.textCtrl.text.isNotEmpty) {
      _initialSnapshot = _TextSessionSnapshot.fromEditor(editor);

      return;
    }

    // New text.
    //
    // PIE has finished mounting its TextEditorState at this point, so apply
    // Wrytte's intended initial appearance once after the current frame.
    if (!_initialStyleScheduled) {
      _initialStyleScheduled = true;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initialStyleScheduled = false;

        if (!editor.mounted || !identical(_editor, editor)) {
          return;
        }

        _applyBackground(
          editor,
          ChatMediaTextBackgroundStyle.light,
          notify: false,
        );

        _applyAlignment(editor, TextAlign.center, notify: false);

        _applyFont(editor, 0, notify: false);

        setFontScale(editor, defaultFontScale, notify: false);

        _initialSnapshot = _TextSessionSnapshot.fromEditor(editor);

        notifyListeners();
      });
    }
  }

  bool hasChanges(TextEditorState editor) {
    final initial = _initialSnapshot;

    if (initial == null) {
      return editor.textCtrl.text.trim().isNotEmpty;
    }

    return !initial.matches(editor);
  }

  void setColor(TextEditorState editor, Color color) {
    editor.primaryColor = color;

    editor.setTextStyle(editor.selectedTextStyle.copyWith(color: color));

    notifyListeners();
  }

  void cycleBackground(TextEditorState editor) {
    final next = switch (backgroundStyle) {
      ChatMediaTextBackgroundStyle.light => ChatMediaTextBackgroundStyle.dark,
      ChatMediaTextBackgroundStyle.dark =>
        ChatMediaTextBackgroundStyle.transparent,
      ChatMediaTextBackgroundStyle.transparent =>
        ChatMediaTextBackgroundStyle.light,
    };

    _applyBackground(editor, next);
  }

  void _applyBackground(
    TextEditorState editor,
    ChatMediaTextBackgroundStyle style, {
    bool notify = true,
  }) {
    final textColor = switch (style) {
      ChatMediaTextBackgroundStyle.light => Colors.black,
      ChatMediaTextBackgroundStyle.dark => Colors.white,
      ChatMediaTextBackgroundStyle.transparent => Colors.white,
    };

    final backgroundColor = switch (style) {
      ChatMediaTextBackgroundStyle.light => Colors.white,
      ChatMediaTextBackgroundStyle.dark => darkBackground,
      ChatMediaTextBackgroundStyle.transparent => Colors.transparent,
    };

    final mode = style == ChatMediaTextBackgroundStyle.transparent
        ? LayerBackgroundMode.onlyColor
        : LayerBackgroundMode.backgroundAndColor;

    editor.setState(() {
      editor.primaryColor = textColor;

      editor.secondaryColor = backgroundColor;

      editor.backgroundColorMode = mode;

      editor.selectedTextStyle = editor.selectedTextStyle.copyWith(
        color: textColor,
      );
    });

    backgroundStyle = style;

    if (notify) {
      notifyListeners();
    }
  }

  void cycleAlignment(TextEditorState editor) {
    final next = switch (alignment) {
      TextAlign.center => TextAlign.right,
      TextAlign.right => TextAlign.left,
      _ => TextAlign.center,
    };

    _applyAlignment(editor, next);
  }

  void _applyAlignment(
    TextEditorState editor,
    TextAlign target, {
    bool notify = true,
  }) {
    var attempts = 0;

    // Use PIE's own state path first.
    while (editor.align != target && attempts < 3) {
      editor.toggleTextAlign();
      attempts++;
    }

    if (editor.align != target) {
      editor.setState(() {
        editor.align = target;
      });
    }

    alignment = target;

    if (notify) {
      notifyListeners();
    }
  }

  void setFontScale(
    TextEditorState editor,
    double requested, {
    bool notify = true,
  }) {
    final next = requested.clamp(minFontScale, maxFontScale).toDouble();

    if ((editor.fontScale - next).abs() < .002) {
      return;
    }

    editor.setState(() {
      editor.fontScale = next;
    });

    fontScale = next;

    if (notify) {
      notifyListeners();
    }
  }

  void selectFont(TextEditorState editor, int index) {
    if (index < 0 || index >= fontPresets.length) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    _applyFont(editor, index);

    restoreKeyboard(editor);
  }

  void _applyFont(TextEditorState editor, int index, {bool notify = true}) {
    final preset = fontPresets[index];

    editor.setTextStyle(
      editor.selectedTextStyle.copyWith(
        fontFamily: preset.fontFamily,
        fontWeight: preset.fontWeight ?? FontWeight.w400,
        fontStyle: preset.fontStyle ?? FontStyle.normal,
      ),
    );

    fontIndex = index;

    if (notify) {
      notifyListeners();
    }
  }

  Future<void> toggleEmoji(TextEditorState editor) async {
    if (emojiVisible) {
      closeEmoji(editor, restoreKeyboard: true);

      return;
    }

    editor.focusNode.unfocus();

    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

    emojiVisible = true;

    notifyListeners();
  }

  void closeEmoji(TextEditorState editor, {bool restoreKeyboard = false}) {
    if (!emojiVisible) {
      if (restoreKeyboard) {
        restoreKeyboardFocus(editor);
      }

      return;
    }

    emojiVisible = false;

    notifyListeners();

    if (restoreKeyboard) {
      restoreKeyboardFocus(editor);
    }
  }

  void restoreKeyboard(TextEditorState editor) {
    closeEmoji(editor, restoreKeyboard: true);
  }

  void restoreKeyboardFocus(TextEditorState editor) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (editor.mounted) {
        editor.focusNode.requestFocus();
      }
    });
  }

  Future<void> discard(TextEditorState editor) async {
    if (busy) {
      return;
    }

    busy = true;
    emojiVisible = false;

    notifyListeners();

    editor.focusNode.unfocus();

    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

    if (!editor.mounted) {
      return;
    }

    // The main editor owns the nested route. Closing through it reliably
    // restores the main editing surface on every supported PIE version.
    onDiscarded();
  }

  Future<void> apply(TextEditorState editor) async {
    if (busy) {
      return;
    }

    if (editor.textCtrl.text.trim().isEmpty) {
      await discard(editor);

      return;
    }

    busy = true;
    emojiVisible = false;

    notifyListeners();

    editor.focusNode.unfocus();

    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

    if (!editor.mounted) {
      return;
    }

    editor.done();
  }

  int _findFontIndex(TextStyle style) {
    for (var index = 0; index < fontPresets.length; index++) {
      final preset = fontPresets[index];

      if (preset.fontFamily == style.fontFamily &&
          (preset.fontStyle ?? FontStyle.normal) ==
              (style.fontStyle ?? FontStyle.normal)) {
        return index;
      }
    }

    return 0;
  }

  ChatMediaTextBackgroundStyle _backgroundStyleFromEditor(
    TextEditorState editor,
  ) {
    if (editor.backgroundColorMode == LayerBackgroundMode.onlyColor ||
        editor.secondaryColor == Colors.transparent) {
      return ChatMediaTextBackgroundStyle.transparent;
    }

    if (editor.secondaryColor.computeLuminance() > .55) {
      return ChatMediaTextBackgroundStyle.light;
    }

    return ChatMediaTextBackgroundStyle.dark;
  }
}

class _TextSessionSnapshot {
  const _TextSessionSnapshot({
    required this.text,
    required this.style,
    required this.align,
    required this.primaryColor,
    required this.secondaryColor,
    required this.backgroundMode,
    required this.fontScale,
  });

  factory _TextSessionSnapshot.fromEditor(TextEditorState editor) {
    return _TextSessionSnapshot(
      text: editor.textCtrl.text,
      style: editor.selectedTextStyle,
      align: editor.align,
      primaryColor: editor.primaryColor,
      secondaryColor: editor.secondaryColor,
      backgroundMode: editor.backgroundColorMode,
      fontScale: editor.fontScale,
    );
  }

  final String text;
  final TextStyle style;

  final TextAlign align;

  final Color primaryColor;
  final Color secondaryColor;

  final LayerBackgroundMode backgroundMode;

  final double fontScale;

  bool matches(TextEditorState editor) {
    return text == editor.textCtrl.text &&
        style == editor.selectedTextStyle &&
        align == editor.align &&
        primaryColor == editor.primaryColor &&
        secondaryColor == editor.secondaryColor &&
        backgroundMode == editor.backgroundColorMode &&
        (fontScale - editor.fontScale).abs() < .002;
  }
}
