import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The NAV/VNT carousels page by listening for [OverscrollNotification]
/// from a ListView that is exactly one viewport tall. That only works if
/// the physics CLAMP at the extents — BouncingScrollPhysics (Flutter's
/// default on iOS, and so also in Safari/iOS on the web build) lets the
/// position travel past them to rubber-band instead, reporting no
/// overscroll at all and leaving the gesture dead.
///
/// Reported live 2026-09-08: vertical dragging worked on Android but not
/// on iOS or the Netlify web build.
Widget _harness({
  required ScrollPhysics physics,
  required void Function(double) onOverscroll,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(400, 600)),
    child: NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is OverscrollNotification) onOverscroll(n.overscroll);
        return false;
      },
      // One viewport-tall child: nothing to actually scroll, exactly like
      // the real carousels.
      child: ListView(
        physics: physics,
        padding: EdgeInsets.zero,
        children: const [SizedBox(height: 600)],
      ),
    ),
  ),
);

void main() {
  testWidgets('bouncing physics reports no overscroll (the iOS bug)', (
    tester,
  ) async {
    var total = 0.0;
    await tester.pumpWidget(
      _harness(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        onOverscroll: (v) => total += v,
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(
      total,
      0.0,
      reason: 'bouncing physics rubber-bands instead of overscrolling, so '
          'the paging listener never fires — this is the reported bug',
    );
  });

  testWidgets('clamping physics reports the overscroll paging needs', (
    tester,
  ) async {
    var total = 0.0;
    await tester.pumpWidget(
      _harness(
        // The exact physics the app now uses for both carousels.
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        onOverscroll: (v) => total += v,
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    // Swiping up must accumulate positive overscroll well past the 60pt
    // the carousels require to flip to the next page.
    expect(total, greaterThan(60));
  });

  testWidgets('clamping physics overscrolls the other way too', (
    tester,
  ) async {
    var total = 0.0;
    await tester.pumpWidget(
      _harness(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        onOverscroll: (v) => total += v,
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(total, lessThan(-60));
  });
}
