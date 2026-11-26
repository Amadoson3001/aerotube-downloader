import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/tokens/colors.dart';
import '../../core/theme/tokens/radius.dart';

/// Shares a single linear shimmer [AnimationController] across all descendant
/// [AeroSkeletonBox] widgets so skeleton lines animate in sync with minimal
/// ticker overhead. Honors [appMotionDuration] (disables when reduce-motion is on).
class AeroShimmerScope extends StatefulWidget {
  final Widget child;
  final Duration duration;

  const AeroShimmerScope({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1350),
  });

  static Animation<double>? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_AeroShimmerInherited>()
        ?.notifier;
  }

  @override
  State<AeroShimmerScope> createState() => _AeroShimmerScopeState();
}

class _AeroShimmerScopeState extends State<AeroShimmerScope>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final effective = appMotionDuration(context, widget.duration);
    if (effective == Duration.zero) {
      _controller?.stop();
    } else {
      final ctrl = _controller ??= AnimationController(
        vsync: this,
        duration: effective,
      );
      if (ctrl.duration != effective) {
        ctrl.duration = effective;
      }
      if (!ctrl.isAnimating) {
        ctrl.repeat();
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AeroShimmerInherited(
      notifier: _controller,
      child: widget.child,
    );
  }
}

class _AeroShimmerInherited extends InheritedNotifier<AnimationController> {
  const _AeroShimmerInherited({
    super.notifier,
    required super.child,
  });
}

/// A skeleton placeholder bar/box that renders a smooth diagonal line shimmer
/// when inside an active [AeroShimmerScope], or a static surface box when
/// motion is disabled.
class AeroSkeletonBox extends StatelessWidget {
  final double? height;
  final double? widthFactor;
  final BorderRadius? borderRadius;
  final double phaseOffset;

  const AeroSkeletonBox({
    super.key,
    this.height,
    this.widthFactor,
    this.borderRadius,
    this.phaseOffset = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final aero = context.aero;
    final animation = AeroShimmerScope.maybeOf(context);
    final radius = borderRadius ?? AeroRadius.smBorderRadius;
    final isAnimating = animation != null && animation.status != AnimationStatus.dismissed;

    Widget box = !isAnimating
        ? Container(
            height: height,
            decoration: BoxDecoration(
              color: aero.surface2,
              borderRadius: radius,
            ),
          )
        : RepaintBoundary(
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, _) {
                final t = (animation.value + phaseOffset) % 1.0;
                final sweep = -2.2 + t * 4.4;
                final mid = Color.lerp(
                  aero.surface3,
                  aero.onSurface,
                  0.08,
                )!;
                final peak = Color.lerp(
                  aero.surface3,
                  aero.primary,
                  0.20,
                )!;
                return Container(
                  height: height,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment(sweep, -0.35),
                      end: Alignment(sweep + 1.5, 0.35),
                      stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
                      colors: [
                        aero.surface2,
                        mid,
                        peak,
                        mid,
                        aero.surface2,
                      ],
                    ),
                  ),
                );
              },
            ),
          );

    if (widthFactor != null && widthFactor! < 1.0) {
      box = FractionallySizedBox(
        widthFactor: widthFactor,
        child: box,
      );
    }
    return box;
  }
}
