// Web build: no dart:io DNS lookup available: the browser's own resolver
// already handles this per request, so just pass the hostname through.
Future<String> resolveHostOnce(String host) async => host;
