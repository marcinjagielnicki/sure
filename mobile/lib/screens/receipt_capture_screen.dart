import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/account.dart';
import '../providers/auth_provider.dart';
import '../services/preferences_service.dart';
import '../services/receipts_service.dart';

/// Photograph (or pick) a receipt and upload it to the account it was paid
/// from. The server creates the transaction and reads the receipt afterwards.
class ReceiptCaptureScreen extends StatefulWidget {
  static const maxPhotos = 5;

  final List<Account> accounts;
  final String? initialAccountId;
  final ReceiptsService? service;
  final Future<String?> Function()? accessTokenLoader;
  final Future<List<XFile>> Function(ImageSource source)? pickImages;

  const ReceiptCaptureScreen({
    super.key,
    required this.accounts,
    this.initialAccountId,
    this.service,
    this.accessTokenLoader,
    this.pickImages,
  });

  @override
  State<ReceiptCaptureScreen> createState() => _ReceiptCaptureScreenState();
}

class _ReceiptCaptureScreenState extends State<ReceiptCaptureScreen> {
  final List<XFile> _photos = [];
  String? _accountId;
  bool _uploading = false;
  late final ReceiptsService _service = widget.service ?? ReceiptsService();

  @override
  void initState() {
    super.initState();
    _accountId = widget.accounts.isNotEmpty ? widget.accounts.first.id : null;
    if (widget.accounts.any((account) => account.id == widget.initialAccountId)) {
      _accountId = widget.initialAccountId;
      return;
    }
    PreferencesService.instance.getLastReceiptAccountId().then((lastId) {
      if (!mounted || lastId == null) return;
      if (widget.accounts.any((account) => account.id == lastId)) {
        setState(() => _accountId = lastId);
      }
    });
  }

  Future<List<XFile>> _pick(ImageSource source) async {
    if (widget.pickImages != null) return widget.pickImages!(source);

    final picker = ImagePicker();
    if (source == ImageSource.camera) {
      final photo = await picker.pickImage(source: source, imageQuality: 85, maxWidth: 2000, maxHeight: 2000);
      return photo == null ? [] : [photo];
    }
    return picker.pickMultiImage(imageQuality: 85, maxWidth: 2000, maxHeight: 2000);
  }

  Future<void> _addPhotos(ImageSource source) async {
    final picked = await _pick(source);
    if (!mounted || picked.isEmpty) return;
    setState(() {
      _photos.addAll(picked.take(ReceiptCaptureScreen.maxPhotos - _photos.length));
    });
  }

  Future<String?> _accessToken() {
    if (widget.accessTokenLoader != null) return widget.accessTokenLoader!();
    return context.read<AuthProvider>().getValidAccessToken();
  }

  Future<void> _upload() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final accountId = _accountId!;

    setState(() => _uploading = true);
    try {
      final token = await _accessToken();
      if (token == null) throw const ReceiptUploadException('unauthorized', unauthorized: true);

      await _service.upload(accessToken: token, accountId: accountId, files: _photos);
      await PreferencesService.instance.setLastReceiptAccountId(accountId);

      messenger.showSnackBar(SnackBar(content: Text(l.receiptUploaded)));
      if (navigator.canPop()) navigator.pop(true);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(l.receiptUploadFailed(error.toString()))));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final canAddMore = _photos.length < ReceiptCaptureScreen.maxPhotos && !_uploading;
    final canUpload = _photos.isNotEmpty && _accountId != null && !_uploading;

    return Scaffold(
      appBar: AppBar(title: Text(l.receiptScanTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_photos.isNotEmpty)
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _PhotoThumbnail(
                    photo: _photos[index],
                    removeTooltip: l.receiptRemovePhoto,
                    onRemove: _uploading ? null : () => setState(() => _photos.removeAt(index)),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(l.receiptMaxPhotos(ReceiptCaptureScreen.maxPhotos), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canAddMore ? () => _addPhotos(ImageSource.camera) : null,
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: Text(l.receiptTakePhoto),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canAddMore ? () => _addPhotos(ImageSource.gallery) : null,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(l.receiptChooseFromGallery),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              value: _accountId,
              decoration: InputDecoration(labelText: l.receiptAccountLabel),
              items: [
                for (final account in widget.accounts)
                  DropdownMenuItem(value: account.id, child: Text(account.name)),
              ],
              onChanged: _uploading ? null : (value) => setState(() => _accountId = value),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: canUpload ? _upload : null,
              child: _uploading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.receiptUpload),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoThumbnail extends StatelessWidget {
  final XFile photo;
  final String removeTooltip;
  final VoidCallback? onRemove;

  const _PhotoThumbnail({required this.photo, required this.removeTooltip, this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: FutureBuilder(
            future: photo.readAsBytes(),
            builder: (context, snapshot) => snapshot.hasData
                ? Image.memory(snapshot.data!, width: 90, height: 120, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const _ThumbnailPlaceholder())
                : const _ThumbnailPlaceholder(),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            tooltip: removeTooltip,
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 90,
      height: 120,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.receipt_long_outlined),
    );
  }
}
