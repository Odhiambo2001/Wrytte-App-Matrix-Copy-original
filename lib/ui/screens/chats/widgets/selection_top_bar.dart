import 'dart:ui';
import 'package:flutter/material.dart';

class SelectionTopBar extends StatefulWidget implements PreferredSizeWidget {
  final int selectedCount;
  final VoidCallback onClose;
  final VoidCallback onMarkAsRead;
  final VoidCallback onPin;
  final VoidCallback onMute;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  const SelectionTopBar({
    super.key,
    required this.selectedCount,
    required this.onClose,
    required this.onMarkAsRead,
    required this.onPin,
    required this.onMute,
    required this.onArchive,
    required this.onDelete,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<SelectionTopBar> createState() => _SelectionTopBarState();
}

class _SelectionTopBarState extends State<SelectionTopBar> {
  bool _isPinned = false;
  bool _isMuted = false;
  bool _isArchived = false;

  static const double _pillHeight = 44.0;
  static const Color _blue = Color(0xFF4DA3FF);
  static const Color _white = Colors.white;
  static const Color _red = Color(0xFFFF3B30);

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;

    return SizedBox(
      height: kToolbarHeight + topInset,
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(25),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                height: _pillHeight,
                decoration: BoxDecoration(
                  color: const Color(0xFF23262C).withValues(alpha: 0.30),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: const Color(0xFF23262C),
                    width: 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    // ── ✕ Close (fixed — slightly wider for the X + count pair)
                    _ActionCell(
                      onTap: widget.onClose,
                      child: const Icon(Icons.close, color: _blue, size: 20),
                    ),

                    // ── Count (intrinsic width, no Expanded) ──────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        '${widget.selectedCount}',
                        style: const TextStyle(
                          color: _blue,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),

                    _VDivider(),

                    // ── Pin / Unpin ───────────────────────────────────────
                    _ActionCell(
                      onTap: () {
                        setState(() => _isPinned = !_isPinned);
                        widget.onPin();
                      },
                      child: Icon(
                        _isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                        color: _white,
                        size: 20,
                      ),
                    ),

                    _VDivider(),

                    // ── Block / Mark as read ──────────────────────────────
                    _ActionCell(
                      onTap: widget.onMarkAsRead,
                      child: const Icon(
                        Icons.block_outlined,
                        color: _white,
                        size: 20,
                      ),
                    ),

                    _VDivider(),

                    // ── Mute / Unmute ─────────────────────────────────────
                    _ActionCell(
                      onTap: () {
                        setState(() => _isMuted = !_isMuted);
                        widget.onMute();
                      },
                      child: Icon(
                        _isMuted
                            ? Icons.volume_up_outlined
                            : Icons.volume_off_outlined,
                        color: _white,
                        size: 20,
                      ),
                    ),

                    _VDivider(),

                    // ── Archive / Unarchive ───────────────────────────────
                    _ActionCell(
                      onTap: () {
                        setState(() => _isArchived = !_isArchived);
                        widget.onArchive();
                      },
                      child: Icon(
                        _isArchived
                            ? Icons.unarchive_outlined
                            : Icons.archive_outlined,
                        color: _white,
                        size: 20,
                      ),
                    ),

                    _VDivider(),

                    // ── Delete ────────────────────────────────────────────
                    _ActionCell(
                      onTap: widget.onDelete,
                      child: const Icon(
                        Icons.delete_outline,
                        color: _red,
                        size: 20,
                      ),
                    ),

                    _VDivider(),

                    // ── More vert ─────────────────────────────────────────
                    _ActionCell(
                      onTap: () {},
                      child: const Icon(
                        Icons.more_vert,
                        color: _white,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Each icon cell takes an equal share of the remaining row width ────────────

class _ActionCell extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _ActionCell({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(height: 44, child: Center(child: child)),
      ),
    );
  }
}

// ── Subtle vertical separator between cells ───────────────────────────────────

class _VDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.5,
      height: 20,
      color: Colors.white.withValues(alpha: 0.12),
    );
  }
}
