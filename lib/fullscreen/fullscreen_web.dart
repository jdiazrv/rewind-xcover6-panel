import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool get fullscreenSupported => web.document.documentElement != null;

bool get fullscreenActive => web.document.fullscreenElement != null;

@JS('rewindToggleFullscreen')
external void _rewindToggleFullscreen();

Future<void> toggleFullscreen() async {
  _rewindToggleFullscreen();
}
