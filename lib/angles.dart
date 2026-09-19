// Ángulos en Dart puro (sin Flutter): lo usan models.dart y también el
// motor de routing y las polares, que se compilan y prueban sin Flutter.

double normalize360(double value) {
  var out = value % 360.0;
  if (out < 0) out += 360.0;
  return out;
}

/// −180…180.
double normalizeRelativeAngle(double value) {
  var out = normalize360(value);
  if (out > 180.0) out -= 360.0;
  return out;
}
