import 'package:flutter/services.dart';

const _channel = MethodChannel('rewind/network');

/// Whether Android reports an active VPN transport right now (Tailscale
/// or any other) — see MainActivity.kt's isVpnActive, which is the only
/// platform this is actually implemented on. Any other native target
/// (iOS, desktop) has no handler registered for this channel at all, so
/// this treats a MissingPluginException the same as "no" rather than
/// letting it propagate — CFG > Admin's per-server VPN gating should
/// degrade to "assume no VPN" there, not crash.
Future<bool> isVpnActive() async {
  try {
    return await _channel.invokeMethod<bool>('isVpnActive') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
