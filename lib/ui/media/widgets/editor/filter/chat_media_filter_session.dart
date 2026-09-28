import 'package:pro_image_editor/pro_image_editor.dart';

class ChatMediaFilterSession {
  FilterEditorState? _editor;
  FilterModel? _initialFilter;

  void attach(
    FilterEditorState editor,
  ) {
    // A new FilterEditorState means a new Filter session.
    //
    // This is important when Filters is opened multiple times during the same
    // main editing session.
    if (identical(
      _editor,
      editor,
    )) {
      return;
    }

    _editor = editor;
    _initialFilter = editor.selectedFilter;
  }

  List<FilterModel> availableFilters(
    FilterEditorState editor,
  ) {
    return editor
            .filterEditorConfigs
            .filterList ??
        presetFiltersList;
  }

  bool hasChanges(
    FilterEditorState editor,
  ) {
    final initial =
        _initialFilter;

    if (initial == null) {
      return false;
    }

    return !sameFilter(
      initial,
      editor.selectedFilter,
    );
  }

  bool isOriginal(
    FilterEditorState editor,
  ) {
    final filters =
        availableFilters(
      editor,
    );

    final selectedName =
        editor
            .selectedFilter
            .name
            .trim()
            .toLowerCase();

    if (selectedName ==
            'original' ||
        selectedName ==
            'no filter' ||
        selectedName ==
            'none') {
      return true;
    }

    if (filters.isEmpty) {
      return true;
    }

    return sameFilter(
      editor.selectedFilter,
      filters.first,
    );
  }

  bool sameFilter(
    FilterModel first,
    FilterModel second,
  ) {
    if (identical(
      first,
      second,
    )) {
      return true;
    }

    if (first.name ==
        second.name) {
      return true;
    }

    return _sameFilterMatrices(
      first.filters,
      second.filters,
    );
  }

  bool _sameFilterMatrices(
    List<List<double>> first,
    List<List<double>> second,
  ) {
    if (identical(
      first,
      second,
    )) {
      return true;
    }

    if (first.length !=
        second.length) {
      return false;
    }

    for (
      var matrixIndex = 0;
      matrixIndex < first.length;
      matrixIndex++
    ) {
      final firstMatrix =
          first[matrixIndex];

      final secondMatrix =
          second[matrixIndex];

      if (firstMatrix.length !=
          secondMatrix.length) {
        return false;
      }

      for (
        var valueIndex = 0;
        valueIndex <
            firstMatrix.length;
        valueIndex++
      ) {
        if ((firstMatrix[valueIndex] -
                    secondMatrix[valueIndex])
                .abs() >
            .0001) {
          return false;
        }
      }
    }

    return true;
  }
}