// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'dart:typed_data';

Future<void> exportPdfReport({required Uint8List bytes, required String filename, required String subject}) async {
  final blob = html.Blob([bytes], 'application/pdf');
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = filename
      ..style.display = 'none'
      ..click();
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}
