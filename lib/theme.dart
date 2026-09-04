import 'package:flutter/material.dart';

// ─── Colors ───────────────────────────────────────────────────────────────────
const cBg = Color(0xff071015);
const cPanel = Color(0xff17232b);
const cPanel2 = Color(0xff20313a);
const cText = Color(0xfff3fbff);
// Lightened from 0xff9fb3bd — still comfortably within the palette's cool
// blue-grey family, but with real headroom for direct-sunlight outdoor use
// (a boat's mounted tablet), where perceived contrast drops well below
// what a WCAG ratio computed against the panel's own dark background
// already showed as acceptable indoors. Reported via external audit,
// fixed 2026-09-04.
const cMuted = Color(0xffb7c8d1);
const cCyan = Color(0xff19c7e8);
const cGreen = Color(0xff4bd06f);
const cOrange = Color(0xffffa329);
const cRed = Color(0xffff5b5b);
const cYellow = Color(0xffffdf4d);
const cPurple = Color(0xffa98bff);

// Default weather point for web/demo use when Signal K has not provided GPS.
const kDefaultWeatherLat = 36.7213;
const kDefaultWeatherLon = -4.4214;
