import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/tokens/colors.dart';
import '../../core/theme/tokens/radius.dart';
import '../../core/theme/tokens/typography.dart';
import 'aero_density.dart';

/// Segmented control for choosing Video or Audio.
class AeroSegmentedControl extends StatelessWidget {
  final bool isAudio;
  final ValueChanged<bool> onChanged;
  final AeroDensity? density;

  const AeroSegmentedControl({
    super.key,
    required this.isAudio,
    required this.onChanged,
    this.density,
  });

  @override
  Widget build(BuildContext context) {
    final aero = context.aero;
    final effectiveDensity = AeroDensity.resolve(context, density);
    final isCompact = effectiveDensity.isCompact;
    final height = isCompact ? 38.0 : 44.0;
    final duration = appMotionDuration(context, AppMotion.medium);
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return Container(
      height: height,
      padding: const EdgeInsets.all(3.0),
      decoration: BoxDecoration(
        color: aero.surface2,
        borderRadius: AeroRadius.mdBorderRadius,
        border: Border.all(color: aero.outline, width: 1.0),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: 0.5,
                child: AnimatedSlide(
                  offset: isAudio ? Offset(isRtl ? -1 : 1, 0) : Offset.zero,
                  duration: duration,
                  curve: AppMotion.emphasized,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: aero.primarySoft,
                      borderRadius: BorderRadius.circular(AeroRadius.md - 3),
                      border: Border.all(color: aero.primary, width: 1.0),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _buildItem(
                  label: 'Video',
                  icon: Symbols.videocam_rounded,
                  isSelected: !isAudio,
                  onTap: () => onChanged(false),
                  aero: aero,
                  isCompact: isCompact,
                  duration: duration,
                ),
              ),
              Expanded(
                child: _buildItem(
                  label: 'Audio',
                  icon: Symbols.audiotrack_rounded,
                  isSelected: isAudio,
                  onTap: () => onChanged(true),
                  aero: aero,
                  isCompact: isCompact,
                  duration: duration,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildItem({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
    required AeroColors aero,
    required bool isCompact,
    required Duration duration,
  }) {
    final color = isSelected ? aero.primary : aero.onSurfaceMuted;
    final textStyle = (isCompact ? AeroText.label : AeroText.bodySm).copyWith(
      fontWeight: FontWeight.w600,
    );

    return Semantics(
      selected: isSelected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AeroRadius.md - 3),
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: color),
          duration: duration,
          curve: AppMotion.emphasized,
          builder: (context, tint, child) => DefaultTextStyle(
            style: textStyle.copyWith(color: tint),
            child: IconTheme.merge(
              data: IconThemeData(color: tint),
              child: child!,
            ),
          ),
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: isCompact ? 16 : 18),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
