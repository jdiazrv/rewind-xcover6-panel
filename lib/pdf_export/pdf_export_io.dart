import 'dart:io';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

Future<void> exportPdfReport({required Uint8List bytes, required String filename, required String subject}) async {
  final file = File('${Directory.systemTemp.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(ShareParams(
    files: [XFile(file.path, mimeType: 'application/pdf')],
    subject: subject,
  ));
}
