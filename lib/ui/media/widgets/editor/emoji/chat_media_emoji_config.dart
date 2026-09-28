import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

EmojiEditorConfigs buildChatMediaEmojiEditorConfigs() {
  return EmojiEditorConfigs(
    checkPlatformCompatibility: !kIsWeb,

    // Comfortable initial size once the emoji becomes a real layer
    // on the main editor canvas.
    initScale: 5,

    style: EmojiEditorStyle(
      // The outer WrytteGlassSurface owns the visible background.
      backgroundColor: Colors.transparent,

      // ---------------------------------------------------------------
      // EMOJI GLYPH
      // ---------------------------------------------------------------
      //
      // The previous 34px+ sizing was too aggressive for the number of
      // grid columns, causing emojis to visually collide with the cell.
      //
      // 30px gives us a normal emoji keyboard feel while preserving the
      // platform emoji font/fallback chain.
      textStyle: DefaultEmojiTextStyle.copyWith(
        fontSize: 30,
        height: 1,
      ),

      // ---------------------------------------------------------------
      // GRID
      // ---------------------------------------------------------------

      emojiViewConfig: const EmojiViewConfig(
        // 7 gives each emoji significantly more horizontal breathing room
        // than the crowded layout in the screenshot.
        columns: 7,

        // Keep the glyph contained within its grid cell.
        emojiSizeMax: 32,

        gridPadding: EdgeInsets.fromLTRB(
          8,
          4,
          8,
          8,
        ),

        horizontalSpacing: 3,
        verticalSpacing: 5,

        recentsLimit: 40,

        backgroundColor: Colors.transparent,

        buttonMode: ButtonMode.MATERIAL,

        replaceEmojiOnLimitExceed: false,

        noRecents: Center(
          child: Text(
            'No recent emoji',
            style: TextStyle(
              color: WrytteColors.textMuted,
              fontFamily: WrytteTypography.primaryFontFamily,
              fontSize: 14,
            ),
          ),
        ),
      ),

      // ---------------------------------------------------------------
      // CATEGORY BAR
      // ---------------------------------------------------------------

      categoryViewConfig: const CategoryViewConfig(
        backgroundColor: Colors.transparent,

        indicatorColor: WrytteColors.primary,

        iconColor: WrytteColors.textMuted,

        iconColorSelected: WrytteColors.textPrimary,

        dividerColor: Colors.transparent,

        recentTabBehavior: RecentTabBehavior.RECENT,
      ),

      // ---------------------------------------------------------------
      // SEARCH
      // ---------------------------------------------------------------
      //
      // We are NOT depending on PIE's search button anymore.
      //
      // chat_media_emoji_sheet.dart gives us a permanently visible Wrytte
      // search field and forwards the query through EmojiEditorState.externSearch.

      searchViewConfig: const SearchViewConfig(
        backgroundColor: Colors.transparent,

        buttonIconColor: WrytteColors.textPrimary,

        inputTextStyle: TextStyle(
          color: WrytteColors.textPrimary,
          fontFamily: WrytteTypography.primaryFontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w400,
        ),

        hintTextStyle: TextStyle(
          color: WrytteColors.textMuted,
          fontFamily: WrytteTypography.primaryFontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w400,
        ),
      ),

      // We don't need PIE's separate bottom search/backspace toolbar because
      // Wrytte owns the search field.
      bottomActionBarConfig: const BottomActionBarConfig(
        enabled: false,
      ),
    ),
  );
}