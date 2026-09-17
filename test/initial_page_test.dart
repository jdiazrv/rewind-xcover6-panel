import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// En los barcos con pantalla fija, la Raspberry enciende y abre la webapp
/// sola. Para que aparezca ya en la pantalla que interesa (PWR en AREA
/// SECADA) la URL la elige, sin tocar nada a mano.
void main() {
  Uri u(String s) => Uri.parse(s);

  test('toma la pantalla del parámetro page', () {
    expect(
      initialPageIdFromUrl(u('http://localhost:3000/rewind-xcover6-panel/?page=PWR')),
      'PWR',
    );
  });

  test('acepta minúsculas', () {
    expect(initialPageIdFromUrl(u('http://x/?page=anc')), 'ANC');
  });

  test('acepta el fragmento, que algunos lanzadores conservan mejor', () {
    expect(initialPageIdFromUrl(u('http://x/#page=TNK')), 'TNK');
    expect(initialPageIdFromUrl(u('http://x/#/page=VNT')), 'VNT');
  });

  test('sin parámetro no impone nada', () {
    expect(initialPageIdFromUrl(u('http://x/rewind-xcover6-panel/')), isNull);
    expect(initialPageIdFromUrl(u('http://x/?page=')), isNull);
  });

  test('una pantalla inventada se ignora en vez de romper la app', () {
    expect(initialPageIdFromUrl(u('http://x/?page=LOQUESEA')), isNull);
    expect(initialPageIdFromUrl(u('http://x/?page=PWR2')), isNull);
  });

  test('el catálogo incluye las pantallas reales', () {
    expect(kPageIdCatalogue, containsAll(['NAV', 'PWR', 'ANC', 'CFG']));
  });
}
