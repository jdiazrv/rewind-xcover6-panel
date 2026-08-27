// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'dart:js' as js;

bool get fullscreenSupported => html.document.documentElement != null;

bool get fullscreenActive => html.document.fullscreenElement != null;

Future<void> toggleFullscreen() async {
  js.context.callMethod('rewindToggleFullscreen');
}
