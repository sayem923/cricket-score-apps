import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/storage_service.dart';

class EditProfileScreen extends StatefulWidget {
  // Passed in from ProfileScreen (already loaded there) so this screen
  // doesn't need its own loading spinner before the form appears; null is
  // fine too (e.g. first time editing, no row yet) - fields just start blank.
  final UserProfile? profile;
  const EditProfileScreen({super.key, this.profile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _bioCtrl;

  String? _avatarUrl;
  Uint8List? _pendingAvatarBytes;
  String? _pendingAvatarExt;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.profile?.name ?? AuthService.currentUserName ?? "");
    _phoneCtrl = TextEditingController(text: widget.profile?.phone ?? "");
    _bioCtrl = TextEditingController(text: widget.profile?.bio ?? "");
    _avatarUrl = widget.profile?.avatarUrl;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85, maxWidth: 640, maxHeight: 640);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _pendingAvatarBytes = bytes;
      _pendingAvatarExt = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
    });
  }

  void _showAvatarOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(leading: const Icon(Icons.camera_alt), title: const Text("Take Photo"), onTap: () { Navigator.pop(context); _pickAvatar(ImageSource.camera); }),
            ListTile(leading: const Icon(Icons.photo_library), title: const Text("Choose from Gallery"), onTap: () { Navigator.pop(context); _pickAvatar(ImageSource.gallery); }),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Name can't be empty")));
      return;
    }
    setState(() => _saving = true);

    String? newAvatarUrl;
    if (_pendingAvatarBytes != null) {
      newAvatarUrl = await StorageService.uploadAvatar(_pendingAvatarBytes!, _pendingAvatarExt ?? 'jpg');
      if (newAvatarUrl == null) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't upload photo - please try again."), backgroundColor: Colors.red));
        return;
      }
    }

    final error = await StorageService.saveProfile(
      name: name,
      avatarUrl: newAvatarUrl,
      bio: _bioCtrl.text.trim(),
      phone: _phoneCtrl.text.trim(),
    );

    if (!mounted) return;
    setState(() => _saving = false);

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
      return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final displayImage = _pendingAvatarBytes != null
        ? MemoryImage(_pendingAvatarBytes!)
        : (_avatarUrl != null ? NetworkImage(_avatarUrl!) : null) as ImageProvider?;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Edit Profile"),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
        actions: [
          _saving
              ? const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)))
              : TextButton(onPressed: _save, child: const Text("SAVE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: const Color(0xFFE0F2F1),
                    backgroundImage: displayImage,
                    child: displayImage == null ? const Icon(Icons.person, size: 50, color: Color(0xFF00695C)) : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: InkWell(
                      onTap: _showAvatarOptions,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(color: Color(0xFF00695C), shape: BoxShape.circle, border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 2))),
                        child: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: "Name", prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: "Phone (optional)", prefixIcon: Icon(Icons.phone_outlined), border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _bioCtrl, maxLines: 4, decoration: const InputDecoration(labelText: "About (optional)", alignLabelWithHint: true, prefixIcon: Icon(Icons.info_outline), border: OutlineInputBorder())),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text("Email: ${AuthService.currentUser?.email ?? '-'} (can't be changed here)", style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ),
          ],
        ),
      ),
    );
  }
}
