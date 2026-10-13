import 'dart:collection';

import 'package:flutter/foundation.dart';

class ChatSelectionViewModel extends ChangeNotifier {
  final LinkedHashSet<String> _selectedMessageIds = LinkedHashSet<String>();

  bool get isSelectionMode => _selectedMessageIds.isNotEmpty;

  int get selectedCount => _selectedMessageIds.length;

  Set<String> get selectedMessageIds =>
      Set<String>.unmodifiable(_selectedMessageIds);

  bool isSelected(String messageId) {
    return _selectedMessageIds.contains(messageId);
  }

  void select(String messageId) {
    final id = messageId.trim();
    if (id.isEmpty || !_selectedMessageIds.add(id)) return;
    notifyListeners();
  }

  void toggle(String messageId) {
    final id = messageId.trim();
    if (id.isEmpty) return;

    if (!_selectedMessageIds.remove(id)) {
      _selectedMessageIds.add(id);
    }

    notifyListeners();
  }

  void clear() {
    if (_selectedMessageIds.isEmpty) return;
    _selectedMessageIds.clear();
    notifyListeners();
  }

  void retainExisting(Iterable<String> messageIds) {
    if (_selectedMessageIds.isEmpty) return;

    final existing = messageIds.toSet();
    final before = _selectedMessageIds.length;
    _selectedMessageIds.removeWhere((id) => !existing.contains(id));

    if (_selectedMessageIds.length != before) {
      notifyListeners();
    }
  }
}
