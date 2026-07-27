import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';

class ChannelGallerySelection {
  final List<XFile> files;
  final String caption;

  const ChannelGallerySelection({required this.files, required this.caption});
}

class ChannelGalleryPicker extends StatefulWidget {
  const ChannelGalleryPicker({super.key});

  @override
  State<ChannelGalleryPicker> createState() => _ChannelGalleryPickerState();
}

class _ChannelGalleryPickerState extends State<ChannelGalleryPicker> {
  final _captionController = TextEditingController();
  List<AssetPathEntity> _albums = [];
  List<AssetEntity> _assets = [];
  final _selected = <AssetEntity>[];
  AssetPathEntity? _album;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAlbums();
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _loadAlbums() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
    );
    if (!mounted) return;
    setState(() {
      _albums = albums;
      _album = albums.isEmpty ? null : albums.first;
    });
    await _loadAssets();
  }

  Future<void> _loadAssets() async {
    final album = _album;
    if (album == null) return;
    setState(() => _loading = true);
    final assets = await album.getAssetListPaged(page: 0, size: 200);
    if (mounted)
      setState(() {
        _assets = assets;
        _loading = false;
      });
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      if (_selected.contains(asset)) {
        _selected.remove(asset);
      } else {
        _selected.add(asset);
      }
    });
  }

  Future<void> _preview(AssetEntity asset) async {
    final file = await asset.file;
    if (!mounted || file == null) return;
    final result = await Navigator.push<ChannelGallerySelection>(
      context,
      MaterialPageRoute(
        builder: (_) => ChannelMediaPreview(file: file),
      ),
    );
    if (mounted && result != null) {
      Navigator.pop(context, result);
    }
  }

  Future<void> _finish() async {
    final files = <XFile>[];
    for (final asset in _selected) {
      final file = await asset.file;
      if (file != null) files.add(XFile(file.path));
    }
    if (mounted && files.isNotEmpty) {
      Navigator.pop(
        context,
        ChannelGallerySelection(files: files, caption: _captionController.text),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = _selected.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF202427),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: PopupMenuButton<AssetPathEntity>(
          onSelected: (album) async {
            setState(() => _album = album);
            await _loadAssets();
          },
          itemBuilder:
              (_) => [
                for (final album in _albums)
                  PopupMenuItem(value: album, child: Text(album.name)),
              ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_album?.name ?? 'Recents'),
              const Icon(Icons.keyboard_arrow_down),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            itemBuilder:
                (_) => const [
                  PopupMenuItem(value: 'albums', child: Text('Albums')),
                ],
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_assets.isEmpty)
            const Center(child: Text('No media found'))
          else
            GridView.builder(
              padding: EdgeInsets.only(bottom: hasSelection ? 86 : 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: _assets.length,
              itemBuilder: (_, index) {
                final asset = _assets[index];
                final selectedIndex = _selected.indexOf(asset);
                return Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        onTap: () => _preview(asset),
                        child: Image(
                          image: AssetEntityImageProvider(
                            asset,
                            isOriginal: false,
                            thumbnailSize: const ThumbnailSize.square(300),
                          ),
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: GestureDetector(
                          onTap: () => _toggle(asset),
                          child: Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                selectedIndex >= 0
                                    ? const Color(0xFF4DA3FF)
                                    : Colors.black26,
                            border: Border.all(color: Colors.white),
                          ),
                          child:
                              selectedIndex >= 0
                                  ? Text('${selectedIndex + 1}')
                                  : null,
                          ),
                        ),
                      ),
                    ],
                );
              },
            ),
          if (hasSelection)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  color: Colors.transparent,
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(
                            minHeight: 40,
                            maxHeight: 120,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF23262C).withOpacity(0.30),
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: const Color(0xFF23262C),
                              width: 1,
                            ),
                          ),
                          child: TextField(
                            controller: _captionController,
                            autofocus: false,
                            minLines: 1,
                            maxLines: 4,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Add a caption...',
                              hintStyle: TextStyle(color: Colors.white38),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFF23262C).withOpacity(0.30),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFF23262C),
                              width: 1,
                            ),
                          ),
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              Icons.send,
                              color: Colors.white.withOpacity(0.70),
                              size: 20,
                            ),
                            onPressed: _finish,
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
    );
  }
}

class ChannelMediaPreview extends StatefulWidget {
  final File file;

  const ChannelMediaPreview({super.key, required this.file});

  @override
  State<ChannelMediaPreview> createState() => _ChannelMediaPreviewState();
}

class _ChannelMediaPreviewState extends State<ChannelMediaPreview> {
  final _captionController = TextEditingController();
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    final extension = widget.file.path.toLowerCase();
    if (extension.endsWith('.mp4') ||
        extension.endsWith('.mov') ||
        extension.endsWith('.webm') ||
        extension.endsWith('.mkv')) {
      _videoController = VideoPlayerController.file(widget.file)
        ..initialize().then((_) {
          if (mounted) setState(() {});
        });
    }
  }

  @override
  void dispose() {
    _captionController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  void _post() {
    Navigator.pop(
      context,
      ChannelGallerySelection(
        files: [XFile(widget.file.path)],
        caption: _captionController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final video = _videoController;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child:
                  video != null && video.value.isInitialized
                      ? GestureDetector(
                        onTap: () {
                          setState(() {
                            video.value.isPlaying ? video.pause() : video.play();
                          });
                        },
                        child: AspectRatio(
                          aspectRatio: video.value.aspectRatio,
                          child: VideoPlayer(video),
                        ),
                      )
                      : Image.file(widget.file, fit: BoxFit.contain),
            ),
            Positioned(
              top: 16,
              left: 16,
              child: CircleAvatar(
                backgroundColor: const Color(0xFF23262C),
                child: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 40, maxHeight: 120),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF23262C).withOpacity(0.30),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: const Color(0xFF23262C)),
                      ),
                      child: TextField(
                        controller: _captionController,
                        minLines: 1,
                        maxLines: 4,
                        style: const TextStyle(color: Colors.white, fontSize: 17),
                        decoration: const InputDecoration(
                          hintText: 'Add a caption...',
                          hintStyle: TextStyle(color: Colors.white38),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFF23262C).withOpacity(0.30),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF23262C)),
                      ),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(Icons.send, color: Colors.white.withOpacity(0.70)),
                        onPressed: _post,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
