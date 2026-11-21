import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../core/router.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/providers.dart';

/// Why a file can't be added. Shown in a danger notice: [lead] in bold, then [message].
class UploadProblem implements Exception {
  const UploadProblem(this.lead, this.message);
  final String? lead;
  final String message;

  @override
  String toString() => [?lead, message].join(' ');
}

const _tooLarge = 'Files can be up to 10 MB. Scan the page instead, or send a smaller photo.';
const _useTypes = 'Use PDF, JPG or PNG.';

/// Extensions the backend accepts, with the media type it expects for each.
const uploadMediaTypes = {
  'pdf': 'application/pdf',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
};

/// Extensions for the file picker.
const uploadExtensions = ['pdf', 'jpg', 'jpeg', 'png'];

String? _ext(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return null;
  return name.substring(i + 1).toLowerCase();
}

/// Media type for [name], or throws [UploadProblem] when the backend won't take it.
String mediaTypeFor(String name) {
  final ext = _ext(name);
  final type = ext == null ? null : uploadMediaTypes[ext];
  if (type != null) return type;
  if (ext == 'heic' || ext == 'heif') throw UploadProblem('$name is a HEIC photo.', _useTypes);
  if (ext == null) throw UploadProblem('We can’t tell what kind of file $name is.', _useTypes);
  throw UploadProblem('$name is a ${ext.toUpperCase()} file.', _useTypes);
}

/// Client-side checks before reading or sending the file. Throws [UploadProblem].
String validateUpload(String name, int? size) {
  final type = mediaTypeFor(name);
  if (size != null && size > AppConfig.maxUploadBytes) {
    throw UploadProblem('$name is ${_mb(size)}.', _tooLarge);
  }
  if (size == 0) throw UploadProblem('$name is empty.', 'Choose another file.');
  return type;
}

/// "14 MB" (rounded up so 10.2 MB never reads as "10 MB").
String _mb(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb >= 10 ? '${mb.ceil()} MB' : formatBytes(bytes);
}

/// Maps backend upload errors to the add-sheet copy.
UploadProblem problemFrom(ApiException e, String name) => switch (e.status) {
      413 => UploadProblem('$name is too large.', _tooLarge),
      415 => UploadProblem('We can’t read $name.', _useTypes),
      422 => UploadProblem('We couldn’t open $name.', 'If the PDF has a password, remove it and try again.'),
      _ => UploadProblem(null, e.message),
    };

/// Validates, uploads and puts the new document into the list.
/// Throws [UploadProblem] with user-facing copy.
Future<Document> uploadDocument(WidgetRef ref, {required List<int> bytes, required String filename}) async {
  final type = validateUpload(filename, bytes.length);
  try {
    final doc = await ref.read(repositoryProvider).upload(bytes: bytes, filename: filename, mediaType: type);
    ref.read(documentsProvider.notifier).upsert(doc);
    return doc;
  } on ApiException catch (e) {
    throw problemFrom(e, filename);
  }
}

/// Opens the processing screen for a freshly uploaded document.
void openProcessing(GoRouter router, Document doc) => router.push(Routes.processing(doc.id));
