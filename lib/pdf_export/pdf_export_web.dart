import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<void> exportPdfReport({required Uint8List bytes, required String filename, required String subject}) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'application/pdf'));
  final url = web.URL.createObjectURL(blob);
  try {
    (web.document.createElement('a') as web.HTMLAnchorElement)
      ..href = url
      ..download = filename
      ..style.display = 'none'
      ..click();
  } finally {
    web.URL.revokeObjectURL(url);
  }
}
