import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:pdfx/pdfx.dart';
import 'package:wrytte/services/attachment_local_store.dart';

class WrytteFileCard extends StatefulWidget {
  final String source;
  final String fileName;
  final Widget? trailing;
  final bool isForwarded;
  final bool profileStyle;

  const WrytteFileCard({
    super.key,
    required this.source,
    required this.fileName,
    this.trailing,
    this.isForwarded = false,
    this.profileStyle = false,
  });

  @override
  State<WrytteFileCard> createState() => _WrytteFileCardState();
}

class _WrytteFileCardState extends State<WrytteFileCard> {
  static final Map<String, Future<_FileDetails>> _detailsTasks = {};
  bool _opening = false;
  late Future<_FileDetails> _details;

  @override
  void initState() {
    super.initState();
    _details = _detailsTasks.putIfAbsent(
      widget.source,
      () => _loadDetails(widget.source, widget.fileName),
    );
  }

  @override
  Widget build(BuildContext context) {
    final extension = _extension(widget.fileName);
    final colors = _typeColors(extension);
    return InkWell(
      onTap: _downloadAndOpen,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:
              widget.profileStyle
                  ? const Color(0xFF171A20)
                  : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.isForwarded)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.forward, size: 15, color: Colors.white60),
                    SizedBox(width: 4),
                    Text(
                      'Forwarded',
                      style: TextStyle(
                        color: Colors.white60,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            FutureBuilder<_FileDetails>(
              future: _details,
              builder:
                  (context, snapshot) =>
                      _buildDocumentPreview(snapshot.data, extension),
            ),
            Row(
              children: [
                Container(
                  width: 42,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.$1,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child:
                      _opening
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : Text(
                            _typeLabel(extension),
                            style: TextStyle(
                              color: colors.$2,
                              fontSize: extension == 'docx' ? 15 : 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      FutureBuilder<_FileDetails>(
                        future: _details,
                        builder: (context, snapshot) {
                          final details = snapshot.data;
                          final parts = <String>[
                            if (details?.unitCount != null)
                              '${details!.unitCount} ${extension == 'ppt' || extension == 'pptx' ? 'slides' : 'pages'}',
                            if (details?.size != null)
                              _formatBytes(details!.size),
                            extension.isEmpty
                                ? 'FILE'
                                : extension.toUpperCase(),
                          ];
                          return Text(
                            parts.join('  •  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (widget.trailing != null)
              Align(alignment: Alignment.bottomRight, child: widget.trailing!),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadAndOpen() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final complete = await AttachmentLocalStore.instance.ensureComplete(
        source: widget.source,
        fileName: widget.fileName,
      );
      final result = await OpenFilex.open(complete.file.path);
      if (result.type != ResultType.done) throw StateError(result.message);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open file: $error'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _buildDocumentPreview(_FileDetails? details, String extension) {
    final preview = details?.preview;
    final slideText = details?.slideText ?? const <String>[];
    if (preview == null && slideText.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      height: 132,
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F5EE),
        borderRadius: BorderRadius.circular(6),
      ),
      child:
          preview != null
              ? Image.memory(
                preview,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
              )
              : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final line in slideText.take(3))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: const Color(0xFF6E1837),
                            fontSize: line == slideText.first ? 18 : 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
    );
  }

  static Future<_FileDetails> _loadDetails(
    String source,
    String displayName,
  ) async {
    final cleanSource = source.trim();
    if (cleanSource.isEmpty) throw StateError('File URL is unavailable');
    final localCopy = await AttachmentLocalStore.instance.ensureInitial(
      source: cleanSource,
      fileName: displayName,
      allowPartial: true,
    );
    final local = localCopy.file;
    final safeName = _safeName(displayName, local.path);
    final isComplete = localCopy.isComplete;
    return _FileDetails(
      file: local,
      size: localCopy.totalBytes ?? await local.length(),
      unitCount:
          isComplete ? await _documentUnits(local, _extension(safeName)) : null,
      preview:
          isComplete ? await _pdfPreview(local, _extension(safeName)) : null,
      slideText:
          isComplete
              ? await _powerPointPreviewText(local, _extension(safeName))
              : const [],
    );
  }

  static Future<Uint8List?> _pdfPreview(File file, String extension) async {
    if (extension != 'pdf') return null;
    PdfDocument? document;
    PdfPage? page;
    try {
      document = await PdfDocument.openFile(file.path);
      page = await document.getPage(1);
      final rendered = await page.render(
        width: page.width * 1.4,
        height: page.height * 1.4,
        format: PdfPageImageFormat.png,
      );
      return rendered?.bytes;
    } catch (_) {
      return null;
    } finally {
      await page?.close();
      await document?.close();
    }
  }

  static Future<List<String>> _powerPointPreviewText(
    File file,
    String extension,
  ) async {
    if (extension != 'pptx') return const [];
    try {
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final slide = archive.findFile('ppt/slides/slide1.xml');
      if (slide == null) return const [];
      final xml = utf8.decode(slide.content as List<int>, allowMalformed: true);
      return RegExp(r'<a:t[^>]*>(.*?)</a:t>', dotAll: true)
          .allMatches(xml)
          .map((match) => _decodeXml(match.group(1) ?? '').trim())
          .where((text) => text.isNotEmpty)
          .toSet()
          .take(5)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String _decodeXml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  static Future<int?> _documentUnits(File file, String extension) async {
    try {
      final bytes = await file.readAsBytes();
      if (extension == 'docx' || extension == 'pptx') {
        final archive = ZipDecoder().decodeBytes(bytes);
        final entry = archive.findFile('docProps/app.xml');
        if (entry == null) return null;
        final xml = utf8.decode(
          entry.content as List<int>,
          allowMalformed: true,
        );
        final tag = extension == 'pptx' ? 'Slides' : 'Pages';
        return int.tryParse(
          RegExp('<$tag>(\\d+)</$tag>').firstMatch(xml)?.group(1) ?? '',
        );
      }
      if (extension == 'pdf') {
        final raw = latin1.decode(bytes, allowInvalid: true);
        return RegExp(r'/Type\s*/Page\b').allMatches(raw).length;
      }
    } catch (_) {}
    return null;
  }

  static String _extension(String name) =>
      p.extension(name).replaceFirst('.', '').toLowerCase();

  static String _safeName(String displayName, String sourcePath) {
    var name = displayName.trim();
    if (name.isEmpty || name.toLowerCase() == 'file') {
      name = p.basename(sourcePath);
    }
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return name.isEmpty ? 'Wrytte file' : name;
  }

  static String _typeLabel(String extension) {
    if (extension == 'doc' || extension == 'docx') return 'W';
    if (extension == 'ppt' || extension == 'pptx') return 'PPT';
    if (extension == 'pdf') return 'PDF';
    if (extension == 'xls' || extension == 'xlsx') return 'XLS';
    return 'FILE';
  }

  static (Color, Color) _typeColors(String extension) {
    if (extension == 'doc' || extension == 'docx') {
      return (const Color(0xFF2B579A), Colors.white);
    }
    if (extension == 'ppt' || extension == 'pptx') {
      return (const Color(0xFFD24726), Colors.white);
    }
    if (extension == 'pdf') return (const Color(0xFFB3261E), Colors.white);
    if (extension == 'xls' || extension == 'xlsx') {
      return (const Color(0xFF217346), Colors.white);
    }
    return (const Color(0xFF5A6472), Colors.white);
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _FileDetails {
  final File file;
  final int size;
  final int? unitCount;
  final Uint8List? preview;
  final List<String> slideText;

  const _FileDetails({
    required this.file,
    required this.size,
    this.unitCount,
    this.preview,
    this.slideText = const [],
  });
}
