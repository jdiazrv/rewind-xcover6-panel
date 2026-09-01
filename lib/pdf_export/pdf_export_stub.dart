import 'dart:typed_data';

Future<void> exportPdfReport({
  required Uint8List bytes,
  required String filename,
  required String subject,
}) async {
  throw UnsupportedError('Exportar PDF no está disponible en esta plataforma');
}
