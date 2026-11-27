import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_motion.dart';
import '../../../core/theme/tokens/colors.dart';
import '../../../core/theme/tokens/radius.dart';
import '../../../core/theme/tokens/typography.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/platform_settings_provider.dart';

class _DesktopNavItemConfig {
  final IconData iconOutlined;
  final IconData iconFilled;
  final String label;
  final String shortcut;
  final bool showBadge;

  const _DesktopNavItemConfig({
    required this.iconOutlined,
    required this.iconFilled,
    required this.label,
    required this.shortcut,
    this.showBadge = false,
  });
}

/// One persistent desktop sidebar. All geometry uses a single smooth
/// [AnimationController] so collapse, expand, and responsive width changes
/// animate continuously without rebuilding static subtrees.
class AppNavigationRail extends StatefulWidget {
  final AnimationController entranceController;

  const AppNavigationRail({super.key, required this.entranceController});

  /// Minimum window width where the sidebar can be expanded.
  /// Below this width it auto-collapses to the 72 px icon rail.
  static const double wideWindowBreakpoint = 840.0;
  static const double collapsedWidth = 72.0;
  static const double expandedWidth = 232.0;
  static const Duration _toggleDuration = Duration(milliseconds: 240);

  @override
  State<AppNavigationRail> createState() => _AppNavigationRailState();
}

class _AppNavigationRailState extends State<AppNavigationRail>
    with SingleTickerProviderStateMixin {
  static const _navItems = [
    _DesktopNavItemConfig(
      iconOutlined: Symbols.home_rounded,
      iconFilled: Symbols.home_rounded,
      label: 'Home',
      shortcut: 'Ctrl+1',
    ),
    _DesktopNavItemConfig(
      iconOutlined: Symbols.search_rounded,
      iconFilled: Symbols.search_rounded,
      label: 'Search',
      shortcut: 'Ctrl+2',
    ),
    _DesktopNavItemConfig(
      iconOutlined: Symbols.download_rounded,
      iconFilled: Symbols.download_rounded,
      label: 'Library',
      shortcut: 'Ctrl+3',
      showBadge: true,
    ),
    _DesktopNavItemConfig(
      iconOutlined: Symbols.settings_rounded,
      iconFilled: Symbols.settings_rounded,
      label: 'Settings',
      shortcut: 'Ctrl+4, Ctrl+,',
    ),
  ];

  late final AnimationController _controller;
  late final Animation<double> _widthCurve;
  late final Animation<double> _detailsOpacity;
  late final Animation<double> _entranceFade;
  late final Animation<Offset> _entranceSlide;

  bool _initialized = false;
  bool _isExpanded = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppNavigationRail._toggleDuration,
      value: 1.0,
    );
    _widthCurve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );
    _detailsOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.15, 1.0, curve: Curves.easeOut),
    );
    _entranceFade = CurvedAnimation(
      parent: widget.entranceController,
      curve: AppMotion.decelerate,
    );
    _entranceSlide = Tween<Offset>(
      begin: const Offset(-0.06, 0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: widget.entranceController,
        curve: AppMotion.decelerate,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = context.watch<PlatformSettingsProvider>();
    final wideWindow =
        MediaQuery.sizeOf(context).width >=
        AppNavigationRail.wideWindowBreakpoint;
    final targetExpanded = settings.isSidebarExpanded && wideWindow;

    if (!_initialized) {
      _initialized = true;
      _isExpanded = targetExpanded;
      _controller.value = targetExpanded ? 1.0 : 0.0;
      return;
    }

    if (targetExpanded != _isExpanded) {
      _isExpanded = targetExpanded;
      final duration = readAppMotionDuration(
        context,
        AppNavigationRail._toggleDuration,
      );
      if (duration == Duration.zero) {
        _controller.value = targetExpanded ? 1.0 : 0.0;
      } else {
        _controller.animateTo(
          targetExpanded ? 1.0 : 0.0,
          duration: duration,
          curve: Curves.linear,
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.aero;
    final settings = context.watch<PlatformSettingsProvider>();
    final wideWindow =
        MediaQuery.sizeOf(context).width >=
        AppNavigationRail.wideWindowBreakpoint;
    final isExpanded = _isExpanded;
    final nav = context.watch<NavigationProvider>();
    final activeCount = context.select<DownloadProvider, int>(
      (p) => p.activeCount,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled = isDark && settings.amoledDark;
    final themeLabel = isAmoled ? 'AMOLED' : (isDark ? 'Dark' : 'Light');
    final loggedIn = settings.isYouTubeLoggedIn;
    final statusColor = loggedIn
        ? colors.success
        : settings.isCookieActive
        ? colors.info
        : colors.onSurfaceFaint;

    final logoBox = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colors.primary,
            colors.primary.withValues(alpha: 0.75),
          ],
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Symbols.play_arrow_rounded,
        size: 20,
        color: Colors.white,
      ),
    );

    final headerDetails = Row(
      children: [
        const SizedBox(width: 10),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: 'Aero',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                    letterSpacing: -0.4,
                  ),
                ),
                TextSpan(
                  text: 'Tube',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 18,
                    fontWeight: FontWeight.w400,
                    color: colors.primary,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
        ),
        Icon(
          Symbols.menu_open_rounded,
          size: 18,
          color: colors.onSurfaceMuted,
        ),
      ],
    );

    final workspaceLabel = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        'WORKSPACE',
        style: AeroText.caption.copyWith(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: colors.onSurfaceFaint,
          letterSpacing: 1.2,
        ),
      ),
    );

    final rail = RepaintBoundary(
      child: AnimatedBuilder(
        animation: _widthCurve,
        builder: (context, _) {
          final expansion = _widthCurve.value.clamp(0.0, 1.0);
          return Container(
            width:
                AppNavigationRail.collapsedWidth +
                (AppNavigationRail.expandedWidth -
                        AppNavigationRail.collapsedWidth) *
                    expansion,
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: colors.surface1,
              border: Border(right: BorderSide(color: colors.outline)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Tooltip(
                  message: wideWindow
                      ? (isExpanded ? 'Collapse sidebar' : 'Expand sidebar')
                      : 'Widen the window to show labels',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: wideWindow
                          ? () => settings.setSidebarExpanded(!isExpanded)
                          : null,
                      child: Container(
                        height: 56,
                        padding: EdgeInsets.symmetric(
                          horizontal: 19.5 - 6.0 * expansion,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: colors.outline),
                          ),
                        ),
                        child: Row(
                          children: [
                            logoBox,
                            Expanded(
                              child: _RailDetails(
                                isExpanded: isExpanded,
                                opacity: _detailsOpacity,
                                width: 172,
                                child: headerDetails,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                ClipRect(
                  child: Align(
                    alignment: Alignment.topLeft,
                    heightFactor: expansion,
                    child: SizedBox(
                      width: AppNavigationRail.expandedWidth,
                      child: FadeTransition(
                        opacity: _detailsOpacity,
                        child: workspaceLabel,
                      ),
                    ),
                  ),
                ),
                if (expansion < 1.0) SizedBox(height: 8.0 * (1.0 - expansion)),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    itemCount: _navItems.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final item = _navItems[index];
                      final selected = nav.currentIndex == index;
                      final count = item.showBadge ? activeCount : 0;
                      return _RailRow(
                        key: ValueKey('sidebar-${item.label}'),
                        expansion: expansion,
                        isExpanded: isExpanded,
                        opacity: _detailsOpacity,
                        selected: selected,
                        tooltip: '${item.label} (${item.shortcut})',
                        onTap: () => nav.setIndex(index),
                        icon: Icon(
                          selected ? item.iconFilled : item.iconOutlined,
                          fill: selected ? 1 : 0,
                          size: 20,
                          color: selected
                              ? colors.primary
                              : colors.onSurfaceMuted,
                        ),
                        badgeCount: count,
                        details: Row(
                          children: [
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AeroText.bodySm.copyWith(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: selected
                                      ? colors.primary
                                      : colors.onSurface,
                                ),
                              ),
                            ),
                            if (count == 0)
                              _Shortcut(
                                text: item.shortcut.split(',').first.trim(),
                              ),
                            if (count > 0) const SizedBox(width: 28),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: colors.outline)),
                  ),
                  child: Column(
                    children: [
                      _RailRow(
                        key: const ValueKey('sidebar-account'),
                        expansion: expansion,
                        isExpanded: isExpanded,
                        opacity: _detailsOpacity,
                        height: 44,
                        tooltip: loggedIn
                            ? 'Signed in (Cookies active)'
                            : 'Guest Account',
                        onTap: () => nav.setIndex(3),
                        icon: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.surface2,
                                border: Border.all(color: colors.outline),
                              ),
                              child: ClipOval(
                                child:
                                    loggedIn &&
                                        settings.youtubeProfileImageUrl != null
                                    ? Image.network(
                                        settings.youtubeProfileImageUrl!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Icon(
                                          Symbols.person_rounded,
                                          size: 15,
                                          color: colors.primary,
                                        ),
                                      )
                                    : Icon(
                                        Symbols.person_rounded,
                                        size: 15,
                                        color: colors.onSurfaceMuted,
                                      ),
                              ),
                            ),
                            Positioned(
                              right: -1,
                              bottom: -1,
                              child: Container(
                                width: 7.5,
                                height: 7.5,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: statusColor,
                                  border: Border.all(
                                    color: colors.surface1,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        details: Row(
                          children: [
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    loggedIn ? 'YouTube User' : 'Guest',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AeroText.bodySm.copyWith(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: colors.onSurface,
                                    ),
                                  ),
                                  Text(
                                    loggedIn
                                        ? 'Signed in'
                                        : settings.isCookieActive
                                        ? 'Cookies active'
                                        : 'Not signed in',
                                    maxLines: 1,
                                    style: AeroText.caption.copyWith(
                                      fontSize: 10,
                                      height: 1.2,
                                      color: statusColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Symbols.chevron_right_rounded,
                              size: 16,
                              color: colors.onSurfaceFaint,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      _RailRow(
                        key: const ValueKey('sidebar-theme'),
                        expansion: expansion,
                        isExpanded: isExpanded,
                        opacity: _detailsOpacity,
                        height: 38,
                        tooltip: 'Toggle theme ($themeLabel)',
                        onTap: () => settings.setThemeMode(
                          isDark ? ThemeMode.light : ThemeMode.dark,
                        ),
                        icon: Icon(
                          isAmoled
                              ? Symbols.contrast_rounded
                              : isDark
                              ? Symbols.dark_mode_rounded
                              : Symbols.light_mode_rounded,
                          size: 18,
                          color: colors.onSurfaceMuted,
                        ),
                        details: Row(
                          children: [
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '$themeLabel Theme',
                                maxLines: 1,
                                style: AeroText.caption.copyWith(
                                  fontSize: 12,
                                  color: colors.onSurfaceMuted,
                                ),
                              ),
                            ),
                            _Shortcut(text: themeLabel),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (!settings.enableAnimations) {
      return rail;
    }

    return FadeTransition(
      opacity: _entranceFade,
      child: SlideTransition(position: _entranceSlide, child: rail),
    );
  }
}

/// Fixed-width text stays mounted and fades smoothly within its shrinking slot.
class _RailDetails extends StatelessWidget {
  final bool isExpanded;
  final Animation<double> opacity;
  final double width;
  final Widget child;

  const _RailDetails({
    required this.isExpanded,
    required this.opacity,
    required this.child,
    this.width = 162,
  });

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !isExpanded,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: width,
        maxWidth: width,
        child: FadeTransition(
          opacity: opacity,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

class _RailRow extends StatefulWidget {
  final double expansion;
  final bool isExpanded;
  final Animation<double> opacity;
  final double height;
  final bool selected;
  final int badgeCount;
  final String tooltip;
  final VoidCallback onTap;
  final Widget icon;
  final Widget details;

  const _RailRow({
    super.key,
    required this.expansion,
    required this.isExpanded,
    required this.opacity,
    required this.tooltip,
    required this.onTap,
    required this.icon,
    required this.details,
    this.height = 42,
    this.selected = false,
    this.badgeCount = 0,
  });

  @override
  State<_RailRow> createState() => _RailRowState();
}

class _RailRowState extends State<_RailRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.aero;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: AeroRadius.smBorderRadius,
            onTap: widget.onTap,
            child: Container(
              height: widget.height,
              decoration: BoxDecoration(
                color: widget.selected
                    ? colors.primarySoft
                    : _hovered
                    ? colors.surface2
                    : Colors.transparent,
                borderRadius: AeroRadius.smBorderRadius,
                border: Border.all(
                  color: widget.selected
                      ? colors.primary.withValues(alpha: 0.28)
                      : _hovered
                      ? colors.outline.withValues(alpha: 0.4)
                      : Colors.transparent,
                ),
              ),
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  if (widget.selected)
                    Positioned(
                      left: 0,
                      top: 8,
                      bottom: 8,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10.5 - widget.expansion,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: Center(child: widget.icon),
                        ),
                        Expanded(
                          child: _RailDetails(
                            isExpanded: widget.isExpanded,
                            opacity: widget.opacity,
                            child: widget.details,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.badgeCount > 0)
                    Positioned(
                      right: 4 + 6 * widget.expansion,
                      top: 2 + 10 * widget.expansion,
                      child: _Shortcut(
                        text: widget.badgeCount > 99
                            ? '99+'
                            : '${widget.badgeCount}',
                        badge: true,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  final String text;
  final bool badge;
  const _Shortcut({required this.text, this.badge = false});
  @override
  Widget build(BuildContext context) {
    final colors = context.aero;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: badge ? colors.primary : colors.surface2,
        borderRadius: BorderRadius.circular(badge ? 12 : 4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: badge ? 'Manrope' : 'Consolas',
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: badge ? colors.onPrimary : colors.onSurfaceFaint,
        ),
      ),
    );
  }
}
