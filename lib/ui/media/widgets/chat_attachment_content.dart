import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:wrytte/domain/models/attachment_contact.dart';
import 'package:wrytte/domain/models/picked_attachment_file.dart';
import 'package:wrytte/domain/models/poll_attachment_draft.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

const _contentPadding = EdgeInsets.fromLTRB(18, 78, 18, 112);

class FileAttachmentContent extends StatelessWidget {
  const FileAttachmentContent({
    super.key,
    required this.scrollController,
    required this.files,
    required this.selectedPaths,
    required this.loading,
    required this.onChooseFiles,
    required this.onChooseAudio,
    required this.onToggle,
  });

  final ScrollController scrollController;
  final List<PickedAttachmentFile> files;
  final Set<String> selectedPaths;
  final bool loading;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseAudio;
  final ValueChanged<PickedAttachmentFile> onToggle;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverPadding(
          padding: _contentPadding,
          sliver: SliverList.list(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _PickerAction(
                      icon: Icons.folder_open_rounded,
                      label: 'Choose files',
                      onTap: loading ? null : onChooseFiles,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PickerAction(
                      icon: Icons.audio_file_rounded,
                      label: 'Choose audio',
                      onTap: loading ? null : onChooseAudio,
                    ),
                  ),
                ],
              ),
              if (loading) ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (files.isEmpty && !loading) ...[
                const SizedBox(height: 56),
                const _EmptyAttachmentState(
                  icon: Icons.description_outlined,
                  title: 'Share a file',
                  message:
                      'Choose documents or audio from your device. Files stay local until you send them.',
                ),
              ] else ...[
                const SizedBox(height: 24),
                const _SectionLabel('Selected from this device'),
                const SizedBox(height: 8),
                for (final file in files)
                  _SelectionRow(
                    icon: _fileIcon(file.extension),
                    title: file.name,
                    subtitle: _fileDetails(file),
                    selected: selectedPaths.contains(file.path),
                    onTap: () => onToggle(file),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static IconData _fileIcon(String extension) => switch (extension) {
    'MP3' || 'M4A' || 'AAC' || 'WAV' || 'OGG' => Icons.graphic_eq_rounded,
    'PDF' => Icons.picture_as_pdf_rounded,
    'ZIP' || 'RAR' || '7Z' => Icons.folder_zip_rounded,
    _ => Icons.insert_drive_file_rounded,
  };

  static String _fileDetails(PickedAttachmentFile file) {
    final bytes = file.sizeBytes;
    final size = bytes >= 1048576
        ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
        : '${(bytes / 1024).clamp(1, 9999).round()} KB';
    return file.extension.isEmpty ? size : '$size · ${file.extension}';
  }
}

class ContactAttachmentContent extends StatefulWidget {
  const ContactAttachmentContent({
    super.key,
    required this.scrollController,
    required this.contacts,
    required this.selectedIds,
    required this.loading,
    required this.accessDenied,
    required this.onRetry,
    required this.onOpenSettings,
    required this.onToggle,
  });

  final ScrollController scrollController;
  final List<AttachmentContact> contacts;
  final Set<String> selectedIds;
  final bool loading;
  final bool accessDenied;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;
  final ValueChanged<AttachmentContact> onToggle;

  @override
  State<ContactAttachmentContent> createState() =>
      _ContactAttachmentContentState();
}
class _ContactAttachmentContentState extends State<ContactAttachmentContent> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final contacts = query.isEmpty
        ? widget.contacts
        : widget.contacts
              .where(
                (contact) =>
                    contact.displayName.toLowerCase().contains(query) ||
                    contact.phoneNumber.contains(query),
              )
              .toList(growable: false);
    return CustomScrollView(
      controller: widget.scrollController,
      slivers: [
        SliverPadding(
          padding: _contentPadding,
          sliver: SliverList.list(
            children: [
              TextField(
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search contacts',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: WrytteColors.surfaceRaised,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: .07),
                    ),
                  ),
                ),
              ),
              if (widget.loading) ...[
                const SizedBox(height: 22),
                const Center(child: CircularProgressIndicator()),
              ] else if (widget.accessDenied) ...[
                const SizedBox(height: 44),
                const _EmptyAttachmentState(
                  icon: Icons.contacts_outlined,
                  title: 'Contacts access is off',
                  message:
                      'Allow contact access to choose exactly who you want to share.',
                ),
                const SizedBox(height: 18),
                Center(
                  child: FilledButton.tonal(
                    onPressed: widget.onOpenSettings,
                    child: const Text('Open settings'),
                  ),
                ),
              ] else if (contacts.isEmpty) ...[
                const SizedBox(height: 44),
                _EmptyAttachmentState(
                  icon: Icons.person_search_outlined,
                  title: query.isEmpty ? 'No contacts found' : 'No matches',
                  message: query.isEmpty
                      ? 'Pull your contacts in again when they become available.'
                      : 'Try a different name or number.',
                ),
                if (query.isEmpty) ...[
                  const SizedBox(height: 18),
                  Center(
                    child: TextButton(
                      onPressed: widget.onRetry,
                      child: const Text('Try again'),
                    ),
                  ),
                ],
              ] else ...[
                const SizedBox(height: 18),
                for (final contact in contacts)
                  _ContactRow(
                    contact: contact,
                    selected: widget.selectedIds.contains(contact.id),
                    onTap: () => widget.onToggle(contact),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class LocationAttachmentContent extends StatelessWidget {
  const LocationAttachmentContent({
    super.key,
    required this.scrollController,
    required this.onChoose,
  });

  final ScrollController scrollController;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverPadding(
          padding: _contentPadding,
          sliver: SliverList.list(
            children: [
              Container(
                height: 190,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF162734), Color(0xFF102019)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(double.infinity, 190),
                      painter: _MapPatternPainter(),
                    ),
                    const Icon(
                      Icons.location_on_rounded,
                      color: WrytteColors.primary,
                      size: 48,
                    ),
                    PositionedDirectional(
                      end: 12,
                      bottom: 12,
                      child: Chip(
                        avatar: const Icon(Icons.map_outlined, size: 17),
                        label: const Text('Map coming later'),
                        side: BorderSide.none,
                        backgroundColor: Colors.black.withValues(alpha: .45),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _ActionRow(
                icon: Icons.my_location_rounded,
                title: 'Send current location',
                subtitle: 'Share your position once',
                onTap: () => onChoose('Current location'),
              ),
              _ActionRow(
                icon: Icons.location_searching_rounded,
                title: 'Share live location',
                subtitle: 'Live maps will be connected in a later step',
                onTap: () => onChoose('Live location'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class PollAttachmentContent extends StatefulWidget {
  const PollAttachmentContent({
    super.key,
    required this.scrollController,
    required this.onChanged,
  });

  final ScrollController scrollController;
  final ValueChanged<PollAttachmentDraft?> onChanged;

  @override
  State<PollAttachmentContent> createState() => _PollAttachmentContentState();
}

class _PollAttachmentContentState extends State<PollAttachmentContent> {
  final _question = TextEditingController();
  final _description = TextEditingController();
  final _options = [
    TextEditingController(),
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multiple = true;

  @override
  void dispose() {
    _question.dispose();
    _description.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  void _notify() {
    final question = _question.text.trim();
    final options = _options
        .take(_options.length - 1)
        .map((controller) => controller.text.trim())
        .where((option) => option.isNotEmpty)
        .toList(growable: false);
    widget.onChanged(
      question.isNotEmpty && options.length >= 2
          ? PollAttachmentDraft(
              question: question,
              options: options,
              description: _description.text.trim().isEmpty
                  ? null
                  : _description.text.trim(),
              allowMultipleAnswers: _multiple,
            )
          : null,
    );
  }

  void _onOptionChanged(int index, String value) {
    if (index == _options.length - 1 &&
        value.trim().isNotEmpty &&
        _options.length < 7) {
      setState(() => _options.add(TextEditingController()));
    } else {
      setState(() {});
    }
    _notify();
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    TextInputAction? textInputAction,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      maxLines: maxLines,
      minLines: maxLines > 1 ? maxLines : 1,
      textInputAction: textInputAction,
      cursorColor: const Color(0xFF6DAAFF),
      style: const TextStyle(
        color: Color(0xFFE9EBEF),
        fontSize: 16,
        height: 1.2,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          color: Color(0xFF5D616A),
          fontSize: 16,
          height: 1.2,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 15,
        ),
      ),
    );
  }

  Widget _glassGroup({required Widget child, bool navbarStyle = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(19),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: navbarStyle
                ? const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, .48, 1],
                    colors: [
                      Color.fromRGBO(26, 29, 37, .44),
                      Color.fromRGBO(15, 18, 25, .36),
                      Color.fromRGBO(8, 10, 15, .30),
                    ],
                  )
                : const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color.fromRGBO(24, 27, 34, .66),
                      Color.fromRGBO(14, 17, 23, .52),
                    ],
                  ),
            borderRadius: BorderRadius.circular(19),
            border: Border.all(
              color: Colors.white.withValues(alpha: navbarStyle ? .09 : .055),
              width: .8,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _optionsEditor() {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _options.length,
      onReorder: (oldIndex, newIndex) {
        final addIndex = _options.length - 1;
        if (oldIndex >= addIndex || newIndex > addIndex) return;
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final option = _options.removeAt(oldIndex);
          _options.insert(newIndex, option);
        });
        _notify();
      },
      proxyDecorator: (child, index, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Material(
          color: const Color(0xFF20242B),
          elevation: 10 * animation.value,
          shadowColor: Colors.black.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(19),
          child: child,
        ),
        child: child,
      ),
      itemBuilder: (context, index) {
        final controller = _options[index];
        final isAddField = index == _options.length - 1;
        return KeyedSubtree(
          key: ValueKey<TextEditingController>(controller),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _field(
                      controller: controller,
                      hint: isAddField ? 'Add an option' : 'Option',
                      textInputAction: TextInputAction.next,
                      onChanged: (value) => _onOptionChanged(index, value),
                    ),
                  ),
                  IgnorePointer(
                    ignoring: isAddField,
                    child: Opacity(
                      opacity: isAddField ? 0 : 1,
                      child: ReorderableDragStartListener(
                        index: index,
                        child: const SizedBox(
                          width: 42,
                          height: 50,
                          child: Icon(
                            Icons.drag_handle_rounded,
                            color: Color(0xFF8E949E),
                            size: 25,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (!isAddField)
                Divider(
                  height: 1,
                  indent: 17,
                  endIndent: 17,
                  color: Colors.white.withValues(alpha: .055),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: widget.scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: _contentPadding,
          sliver: SliverList.list(
            children: [
              const Padding(
                padding: EdgeInsetsDirectional.only(start: 14),
                child: _SectionLabel('Question'),
              ),
              const SizedBox(height: 9),
              _glassGroup(
                child: Column(
                  children: [
                    _field(
                      controller: _question,
                      hint: 'Ask question',
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => _notify(),
                    ),
                    Divider(
                      height: 1,
                      indent: 17,
                      endIndent: 17,
                      color: Colors.white.withValues(alpha: .055),
                    ),
                    _field(
                      controller: _description,
                      hint: 'Add description (optional)',
                      maxLines: 2,
                      textInputAction: TextInputAction.newline,
                      onChanged: (_) => _notify(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Padding(
                padding: EdgeInsetsDirectional.only(start: 14),
                child: _SectionLabel('Options'),
              ),
              const SizedBox(height: 9),
              _glassGroup(child: _optionsEditor()),
              const SizedBox(height: 24),
              _glassGroup(
                navbarStyle: true,
                child: SizedBox(
                  height: 55,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 18,
                      end: 7,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Allow multiple answers',
                            style: TextStyle(
                              color: Color(0xFFE0E2E7),
                              fontSize: 16,
                            ),
                          ),
                        ),
                        Semantics(
                          button: true,
                          toggled: _multiple,
                          label: 'Allow multiple answers',
                          child: GestureDetector(
                            onTap: () {
                              setState(() => _multiple = !_multiple);
                              _notify();
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOutCubic,
                              width: 55,
                              height: 32,
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: _multiple
                                    ? const Color(0xFF69A9FF)
                                    : const Color(0xFF383C45),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: AnimatedAlign(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOutCubic,
                                alignment: _multiple
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFF7F9FC),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PickerAction extends StatelessWidget {
  const _PickerAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WrytteColors.surfaceRaised,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          height: 88,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: WrytteColors.primary, size: 28),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionRow extends StatelessWidget {
  const _SelectionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: WrytteColors.surfaceRaised,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: WrytteColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      style: const TextStyle(
                        color: WrytteColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _SelectionCheck(selected: selected),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.contact,
    required this.selected,
    required this.onTap,
  });

  final AttachmentContact contact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final initial = contact.displayName.trim().isEmpty
        ? '?'
        : contact.displayName.trim().characters.first.toUpperCase();
    return _SelectionRow(
      icon: Icons.person_rounded,
      title: '$initial  ${contact.displayName}',
      subtitle: contact.phoneNumber,
      selected: selected,
      onTap: onTap,
    );
  }
}

class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 150),
      width: 25,
      height: 25,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? WrytteColors.primary : Colors.transparent,
        border: Border.all(
          color: selected
              ? WrytteColors.primary
              : Colors.white.withValues(alpha: .34),
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, color: Colors.white, size: 17)
          : null,
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _SelectionRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    selected: false,
    onTap: onTap,
  );
}

class _PollField extends StatelessWidget {
  const _PollField({
    required this.controller,
    required this.hintText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: onChanged,
    maxLength: 120,
    decoration: InputDecoration(
      hintText: hintText,
      counterText: '',
      filled: true,
      fillColor: WrytteColors.surfaceRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: Color(0xFF9A9DA5),
      fontSize: 15,
      fontWeight: FontWeight.w500,
    ),
  );
}

class _EmptyAttachmentState extends StatelessWidget {
  const _EmptyAttachmentState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, size: 44, color: WrytteColors.textMuted),
      const SizedBox(height: 12),
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 7),
      Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: WrytteColors.textMuted, height: 1.35),
      ),
    ],
  );
}

class _MapPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var x = -40.0; x < size.width + 40; x += 52) {
      canvas.drawLine(Offset(x, 0), Offset(x + 90, size.height), paint);
    }
    for (var y = 20.0; y < size.height; y += 56) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - 18), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

