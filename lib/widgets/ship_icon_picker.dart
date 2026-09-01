import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../boat_icons.dart';
import '../theme.dart';

// Bow-up artwork rotated 90° clockwise so it reads bow-right, matching the
// "en horizontal orientado hacia la derecha" preview convention used both
// here and in the CFG > Pantalla row. FittedBox scales the rotated image up
// to fill whatever space it's given — sizing it explicitly small (as before)
// left a big dead gap between the drawing and the label under it.
Widget _rotatedIcon(String asset) => FittedBox(
  fit: BoxFit.contain,
  child: Transform.rotate(angle: math.pi / 2, child: Image.asset(asset)),
);

Future<void> showShipIconPicker(
  BuildContext context,
  String currentId,
  ValueChanged<String> onSelected,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final screen = MediaQuery.of(ctx).size;
      // Fewer columns on a narrow (phone) screen than on the tablet's wide
      // landscape layout — still no scrolling needed to see every option,
      // just arranged to actually fit the width available.
      final crossAxisCount = screen.width < 420
          ? 2
          : screen.width < 700
          ? 3
          : 4;
      return Dialog(
        backgroundColor: cPanel,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(940, screen.width * 0.95),
            maxHeight: screen.height * 0.9,
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Icono del barco',
                  style: TextStyle(
                    color: cText,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: GridView.count(
                      crossAxisCount: crossAxisCount,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      // 20% shorter than the width-matched square (1.1 →
                      // 1.375) — the FittedBox icon fills either shape
                      // fine, so the card doesn't need to be so tall.
                      childAspectRatio: 1.375,
                      children: [
                        for (final opt in kBoatIconOptions)
                          _IconCard(
                            option: opt,
                            selected: opt.id == currentId,
                            onTap: () {
                              onSelected(opt.id);
                              Navigator.of(ctx).pop();
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Cerrar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _IconCard extends StatelessWidget {
  const _IconCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });
  final BoatIconOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? cCyan : Colors.white12,
          width: selected ? 2 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: _rotatedIcon(option.grandeAsset),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            option.label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? cCyan : cText,
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );
}
