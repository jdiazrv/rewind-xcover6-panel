import 'package:pdf/pdf.dart';

// ─── PDF export theme (mirrors the on-screen dark theme) ─────────────────────
// Deliberately a light print theme, not a copy of the on-screen dark
// palette: pastel accents readable on near-black lose contrast on white
// paper, so these are darker/more saturated versions for legibility.
const pdfBg = PdfColor.fromInt(0xffffffff);
const pdfPanel = PdfColor.fromInt(0xfff2f5f7);
const pdfGrid = PdfColor.fromInt(0xffd8e1e7);
const pdfText = PdfColor.fromInt(0xff17232b);
const pdfMuted = PdfColor.fromInt(0xff5c6f7a);
const pdfCyan = PdfColor.fromInt(0xff0e93ab);
const pdfGreen = PdfColor.fromInt(0xff1f9d52);
const pdfOrange = PdfColor.fromInt(0xffcc7a00);
const pdfRed = PdfColor.fromInt(0xffd23d3d);
const pdfYellow = PdfColor.fromInt(0xffb8860b);
const pdfPurple = PdfColor.fromInt(0xff6f4fc9);
const pdfTeal = PdfColor.fromInt(0xff1f8a7d);
const pdfDarkRed = PdfColor.fromInt(0xff8f2a2a);
