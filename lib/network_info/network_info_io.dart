import 'package:flutter/services.dart';

const _channel = MethodChannel('rewind/network');

/// Whether a VPN transport (Tailscale or any other) is active right now —
/// null when this platform can't actually answer that (see MainActivity.
/// kt's isVpnActive, the only real implementation, Android-only), true/
/// false only ever come from a genuine platform answer. Previously this
/// collapsed "can't tell" into false, which CFG > Admin's per-server row
/// then read as "definitely no VPN" and skipped the reachability probe
/// entirely — on a platform that simply never implemented the check (iOS
/// has no handler registered for this channel), that hid real connectivity
/// info instead of just being neutral about it. Verified real via external
/// audit, fixed 2026-09-04.
Future<bool?> isVpnActive() async {
  try {
    return await _channel.invokeMethod<bool>('isVpnActive');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
