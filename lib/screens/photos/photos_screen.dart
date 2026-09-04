import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../services/auth_service.dart';
import '../../l10n/app_strings.dart';

class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key});

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  List<PhotoEntry> _photos = [];
  bool _loading = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!AuthService.isLoggedIn) {
      setState(() => _loading = false);
      return;
    }
    final photos = await StorageService.loadPhotos();
    if (!mounted) return;
    setState(() {
      _photos = photos;
      _loading = false;
    });
  }

  Future<void> _pick(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    setState(() => _uploading = true);
    final bytes = await picked.readAsBytes();
    final ext = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
    final error = await StorageService.uploadPhoto(bytes, ext);
    if (!mounted) return;
    setState(() => _uploading = false);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
      return;
    }
    _load();
  }

  void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(tr('take_photo')),
              onTap: () {
                Navigator.pop(context);
                _pick(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(tr('choose_from_gallery')),
              onTap: () {
                Navigator.pop(context);
                _pick(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deletePhoto(PhotoEntry photo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('delete_photo_title')),
        content: Text(tr('cant_be_undone')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel').toUpperCase())),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('delete').toUpperCase(), style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    await StorageService.deletePhoto(photo);
    if (!mounted) return;
    setState(() => _photos.removeWhere((p) => p.id == photo.id));
    if (Navigator.canPop(context)) Navigator.pop(context); // close the viewer if open
  }

  void _openViewer(PhotoEntry photo) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            actions: [IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deletePhoto(photo))],
          ),
          body: Center(child: InteractiveViewer(child: Image.network(photo.url))),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = AuthService.isLoggedIn;
    return Scaffold(
      appBar: AppBar(title: Text(tr('photos_title')), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
      body: !loggedIn
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 40, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text(tr('login_to_view_photos'), style: TextStyle(color: Colors.grey[600]), textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    _photos.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(tr('no_photos_yet'), style: TextStyle(color: Colors.grey[600]), textAlign: TextAlign.center),
                            ),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
                            itemCount: _photos.length,
                            itemBuilder: (context, index) {
                              final photo = _photos[index];
                              return GestureDetector(
                                onTap: () => _openViewer(photo),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    photo.url,
                                    fit: BoxFit.cover,
                                    loadingBuilder: (context, child, progress) => progress == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                                    errorBuilder: (context, error, stack) => Container(color: Colors.grey[200], child: const Icon(Icons.broken_image, color: Colors.grey)),
                                  ),
                                ),
                              );
                            },
                          ),
                    if (_uploading)
                      Container(
                        color: Colors.black26,
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
      floatingActionButton: loggedIn
          ? FloatingActionButton(onPressed: _uploading ? null : _showAddOptions, backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white, child: const Icon(Icons.add_a_photo))
          : null,
    );
  }
}
