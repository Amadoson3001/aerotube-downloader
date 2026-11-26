import 'package:material_symbols_icons/symbols.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../core/theme/tokens/colors.dart';
import '../../core/theme/tokens/radius.dart';
import '../../core/theme/tokens/spacing.dart';
import '../../core/theme/tokens/typography.dart';
import '../../core/utils/error_helper.dart';
import '../../core/utils/platform_utils.dart';
import '../../providers/download_provider.dart';
import '../../providers/mobile_download_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/platform_settings_provider.dart';
import '../../providers/tool_update_provider.dart';
import '../../providers/update_provider.dart';
import '../../services/core/android_storage_service.dart';
import '../../services/core/logging_service.dart';
import '../components/aero_button.dart';
import '../components/aero_chip.dart';
import '../components/aero_density.dart';
import '../components/aero_dialog.dart';
import '../components/aero_snack.dart';
import '../components/aero_text_field.dart';
import '../components/component_gallery_screen.dart';
import '../components/empty_state.dart';
import '../components/section_header.dart';
import '../components/settings_row.dart';
import '../components/status_pill.dart';
import '../widgets/app_logo.dart';
import '../widgets/bug_report_dialog.dart';
import '../widgets/error_details_dialog.dart';
import '../widgets/floating_progress_overlay.dart';
import '../widgets/logs_viewer.dart';
import '../widgets/update_dialog.dart';

part 'settings_rows.dart';

/// Redesigned AeroTube Settings Screen following Section 7.5 of the Redesign Spec.
///
/// Features:
/// - Max width 720 px on Windows (centered)
/// - Search field at top of Settings for quick filtering across all settings
/// - Groups with [SectionHeader]:
///   1. Tools (yt-dlp and FFmpeg versions, updates, and advanced options)
///   2. Account
///   3. Downloads (folder, quality, concurrency, naming, subtitles, storage permission)
///   4. Appearance (theme, animations toggle, density)
///   5. Notifications & Background (notifications, SponsorBlock, unrestricted battery, OEM autostart, archive)
///   6. Advanced (logs viewer, export logs, bug report, Component Gallery entry, logging toggle)
///   7. About (App logo, app version, updater)
/// - Destructive actions (Log out, Clear history) styled as danger ghost buttons confirming via [AeroDialog]
/// - All tiles styled using [SettingsRow] and Aero design tokens
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  String _appVersion = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _searchFilter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAppVersion();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<PlatformSettingsProvider>();
      if (provider.isAndroid) {
        provider.refreshBatteryOptimizationStatus();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      final provider = context.read<PlatformSettingsProvider>();
      if (provider.isAndroid) {
        provider.refreshBatteryOptimizationStatus();
      }
    }
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = info.version;
        });
      }
    } catch (_) {
      // Ignore platform version lookup failures (e.g. headless test runners).
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibility = context
        .select<
          PlatformSettingsProvider,
          ({
            bool isAndroid,
            bool enableCookies,
            bool isYouTubeLoggedIn,
            bool isAggressiveOem,
          })
        >(
          (p) => (
            isAndroid: p.isAndroid,
            enableCookies: p.enableCookies,
            isYouTubeLoggedIn: p.isYouTubeLoggedIn,
            isAggressiveOem: p.isAggressiveOem,
          ),
        );
    final isDesktop = !PlatformUtils.isMobile;
    final rows = _buildVisibleRows(context, visibility);
    final rowIndices = <Key, int>{
      for (var i = 0; i < rows.length; i++)
        ValueKey('settings_item_${rows[i].id}'): i,
    };

    Widget body = CustomScrollView(
      key: const PageStorageKey('settings_scroll'),
      controller: _scrollController,
      // Prepare nearby rows before they enter the viewport. Visited rows are
      // retained by _RetainedSettingsRow, so reversing direction reuses them.
      scrollCacheExtent: const ScrollCacheExtent.viewport(1),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.symmetric(
            horizontal: isDesktop ? AeroSpace.xxl : AeroSpace.lg,
            vertical: AeroSpace.lg,
          ),
          sliver: SliverList.builder(
            itemCount: rows.length,
            findChildIndexCallback: (key) => rowIndices[key],
            itemBuilder: (context, index) => _RetainedSettingsRow(
              key: ValueKey('settings_item_${rows[index].id}'),
              row: rows[index],
            ),
          ),
        ),
      ],
    );

    if (isDesktop) {
      body = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: body,
        ),
      );
    }

    return SafeArea(
      child: Stack(
        children: [
          body,
          const RepaintBoundary(
            child: FloatingProgressOverlay(showDownloadProgress: false),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AeroSpace.xs, bottom: AeroSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Settings',
                  style: AeroText.headline.copyWith(
                    fontWeight: FontWeight.w800,
                    color: context.aero.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Personalize downloads, appearance, and tools',
                  style: AeroText.bodySm.copyWith(
                    color: context.aero.onSurfaceMuted,
                  ),
                ),
              ],
            ),
          ),
          if (PlatformUtils.isAndroid)
            IconButton(
              icon: Icon(
                Symbols.home_rounded,
                size: 22,
                color: context.aero.onSurfaceMuted,
              ),
              tooltip: 'Home',
              onPressed: () =>
                  context.read<NavigationProvider>().switchToHome(),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _searchController,
      builder: (context, value, _) {
        return AeroTextField(
          controller: _searchController,
          hintText: 'Search settings…',
          prefixIcon: const Icon(Symbols.search_rounded),
          suffixIcon: value.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Symbols.close_rounded, size: 18),
                  tooltip: 'Clear',
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchFilter = '');
                  },
                )
              : null,
          onChanged: (text) => setState(() => _searchFilter = text.trim()),
        );
      },
    );
  }

  List<_LazySettingsRow> _buildVisibleRows(
    BuildContext context,
    ({
      bool isAndroid,
      bool enableCookies,
      bool isYouTubeLoggedIn,
      bool isAggressiveOem,
    })
    visibility,
  ) {
    final q = _searchFilter.trim().toLowerCase();
    final rows = <_LazySettingsRow>[
      _WidgetSettingsRow('header', (ctx) => _buildHeader(ctx)),
      _WidgetSettingsRow(
        'search_gap',
        (_) => const SizedBox(height: AeroSpace.lg),
      ),
      _WidgetSettingsRow('search', (ctx) => _buildSearchField(ctx)),
    ];

    final sections = <({String title, List<_SettingItemSpec> items})>[
      (title: 'Tools', items: _getToolsSpecs()),
      (title: 'Account', items: _getAccountSpecs(visibility)),
      (title: 'Downloads', items: _getDownloadsSpecs(visibility)),
      (title: 'Appearance', items: _getAppearanceSpecs()),
      (
        title: 'Notifications & Background',
        items: _getBackgroundSpecs(visibility),
      ),
      (title: 'Advanced', items: _getAdvancedSpecs()),
      (title: 'About', items: _getAboutSpecs()),
    ];

    var hasAnyMatch = false;
    var hasAboutMatch = false;

    for (final section in sections) {
      // Filter lightweight metadata BEFORE constructing any row widget.
      final matching = q.isEmpty
          ? section.items
          : section.items.where((spec) => spec.matches(q)).toList();
      if (matching.isEmpty) continue;
      hasAnyMatch = true;
      if (section.title == 'About') hasAboutMatch = true;

      rows.add(_SectionHeaderSettingsRow(section.title));
      for (var i = 0; i < matching.length; i++) {
        rows.add(
          _CardItemSettingsRow(
            spec: matching[i],
            isFirst: i == 0,
            isLast: i == matching.length - 1,
          ),
        );
      }
    }

    if (!hasAnyMatch && q.isNotEmpty) {
      rows.add(
        _WidgetSettingsRow(
          'empty',
          (_) => Padding(
            padding: const EdgeInsets.only(top: AeroSpace.xxl),
            child: EmptyState(
              icon: Symbols.search_off_rounded,
              title: 'No Settings Found',
              description: 'No settings match "$_searchFilter"',
              actionLabel: 'Clear Filter',
              onAction: () {
                _searchController.clear();
                setState(() => _searchFilter = '');
              },
            ),
          ),
        ),
      );
    } else if (hasAboutMatch) {
      rows.add(
        _WidgetSettingsRow(
          'footer_gap',
          (_) => const SizedBox(height: AeroSpace.xl),
        ),
      );
      rows.add(_WidgetSettingsRow('footer', (ctx) => _buildAboutFooter(ctx)));
    }

    rows.add(
      _WidgetSettingsRow(
        'bottom_gap',
        (_) => const SizedBox(height: AeroSpace.xxl * 2),
      ),
    );
    return rows;
  }

  List<_SettingItemSpec> _getAccountSpecs(
    ({
      bool isAndroid,
      bool enableCookies,
      bool isYouTubeLoggedIn,
      bool isAggressiveOem,
    })
    visibility,
  ) {
    return [
      _SettingItemSpec(
        id: 'account_status',
        title: 'Account Status',
        description: 'YouTube session and cookie authentication status',
        keywords: ['status', 'google', 'profile', 'auth', 'signed in', 'guest'],
        builder: (_) => const _AccountStatusRow(),
      ),
      _SettingItemSpec(
        id: 'youtube_login',
        title: 'Sign in with YouTube',
        description: 'Access members-only videos',
        keywords: ['login', 'sign in', 'authenticate', 'webview', 'channel'],
        builder: (ctx) => SettingsRow(
          title: 'Sign in with YouTube',
          subtitle: 'Access members-only videos',
          icon: Symbols.login_rounded,
          onTap: () async {
            final result = await Navigator.pushNamed(ctx, '/youtube_login');
            if (result == true && ctx.mounted) {
              await ctx
                  .read<PlatformSettingsProvider>()
                  .onYouTubeLoginComplete();
            }
          },
        ),
      ),
      if (!visibility.isAndroid)
        _SettingItemSpec(
          id: 'browser_cookies',
          title: 'Browser Cookies',
          description: 'Select browser profile for YouTube cookies',
          keywords: [
            'chrome',
            'firefox',
            'edge',
            'brave',
            'cookies',
            'browser',
          ],
          builder: (_) => _BrowserCookiesRow(host: this),
        ),
      _SettingItemSpec(
        id: 'enable_cookies',
        title: 'Enable Cookies File',
        description: 'Import Netscape format cookies.txt',
        keywords: ['cookies.txt', 'netscape', 'cookie', 'file'],
        builder: (_) => _SettingsSwitchRow(
          title: 'Enable Cookies File',
          subtitle: 'Import Netscape format cookies.txt',
          icon: Symbols.file_copy_rounded,
          selector: (p) => p.enableCookies,
          onChanged: (p, v) => p.setEnableCookies(v),
        ),
      ),
      if (visibility.enableCookies)
        _SettingItemSpec(
          id: 'import_cookies',
          title: 'Import cookies.txt',
          description: 'Select Netscape cookies.txt file',
          keywords: ['upload', 'cookies.txt', 'netscape', 'import'],
          builder: (_) => const _ImportCookiesRow(),
        ),
      if (visibility.isYouTubeLoggedIn)
        _SettingItemSpec(
          id: 'logout_youtube',
          title: 'Log out of YouTube',
          description: 'Disconnect YouTube account and remove active session',
          keywords: ['logout', 'sign out', 'disconnect', 'leave', 'remove'],
          builder: (ctx) => Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AeroSpace.lg,
              vertical: AeroSpace.md,
            ),
            child: Row(
              children: [
                AeroButton.danger(
                  text: 'Log out of YouTube',
                  icon: const Icon(Symbols.logout_rounded, size: 16),
                  density: AeroDensity.compact,
                  onPressed: () =>
                      _confirmLogout(ctx, ctx.read<PlatformSettingsProvider>()),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  List<_SettingItemSpec> _getDownloadsSpecs(
    ({
      bool isAndroid,
      bool enableCookies,
      bool isYouTubeLoggedIn,
      bool isAggressiveOem,
    })
    visibility,
  ) {
    return [
      _SettingItemSpec(
        id: 'download_location',
        title: 'Download Location',
        description: 'Choose folder where downloaded media is saved',
        keywords: ['folder', 'directory', 'path', 'save', 'storage', 'output'],
        builder: (_) => const _DownloadLocationRow(),
      ),
      if (visibility.isAndroid)
        _SettingItemSpec(
          id: 'storage_access',
          title: 'Storage Access',
          description: 'Manage public storage write permissions',
          keywords: ['permission', 'storage', 'sd card', 'android', 'access'],
          builder: (ctx) => _AndroidStoragePermissionTile(
            provider: ctx.read<PlatformSettingsProvider>(),
          ),
        ),
      _SettingItemSpec(
        id: 'default_quality',
        title: 'Default Quality',
        description: 'Preferred video resolution or audio-only preset',
        keywords: [
          'resolution',
          '1080p',
          '4k',
          '720p',
          'audio',
          'format',
          'quality',
        ],
        builder: (_) => _DefaultQualityRow(host: this),
      ),
      _SettingItemSpec(
        id: 'default_subtitle_language',
        title: 'Default Subtitle Language',
        description: 'Preferred subtitle language for downloads',
        keywords: [
          'subtitles',
          'captions',
          'language',
          'english',
          'auto',
          'subs',
        ],
        builder: (_) => _DefaultSubtitleRow(host: this),
      ),
      _SettingItemSpec(
        id: 'concurrent_downloads',
        title: 'Concurrent Downloads',
        description: 'Max parallel background downloads',
        keywords: [
          'concurrency',
          'parallel',
          'threads',
          'simultaneous',
          'speed',
          'limit',
        ],
        builder: (_) => const _ConcurrentDownloadsControl(),
      ),
      _SettingItemSpec(
        id: 'file_naming',
        title: 'File Naming Pattern',
        description: '%(title)s [%(resolution)s].%(ext)s',
        keywords: [
          'naming',
          'filename',
          'format',
          'template',
          'pattern',
          'title',
        ],
        builder: (_) => const SettingsRow(
          title: 'File Naming Pattern',
          subtitle: '%(title)s [%(resolution)s].%(ext)s',
          icon: Symbols.badge_rounded,
          trailing: StatusPill(label: 'Standard', type: StatusPillType.neutral),
        ),
      ),
      _SettingItemSpec(
        id: 'embed_thumbnail',
        title: 'Embed Thumbnail',
        description: 'Add video thumbnail as cover artwork',
        keywords: ['cover', 'album art', 'image', 'picture', 'thumbnail'],
        builder: (_) => _SettingsSwitchRow(
          title: 'Embed Thumbnail',
          subtitle: 'Add video thumbnail as cover artwork',
          icon: Symbols.image_rounded,
          selector: (p) => p.embedThumbnail,
          onChanged: (p, v) => p.setEmbedThumbnail(v),
        ),
      ),
      _SettingItemSpec(
        id: 'embed_metadata',
        title: 'Embed Metadata',
        description: 'Include video details and tags in file metadata',
        keywords: ['tags', 'artist', 'description', 'info', 'metadata'],
        builder: (_) => _SettingsSwitchRow(
          title: 'Embed Metadata',
          subtitle: 'Include video details and tags in file metadata',
          icon: Symbols.info_rounded,
          selector: (p) => p.embedMetadata,
          onChanged: (p, v) => p.setEmbedMetadata(v),
        ),
      ),
      _SettingItemSpec(
        id: 'clear_history',
        title: 'Clear Download History',
        description: 'Remove completed history items without deleting files',
        keywords: ['delete', 'remove', 'history', 'clean', 'clear'],
        builder: (ctx) => Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AeroSpace.lg,
            vertical: AeroSpace.md,
          ),
          child: Row(
            children: [
              Flexible(
                child: AeroButton.danger(
                  text: 'Clear download history',
                  icon: const Icon(Symbols.delete_rounded, size: 16),
                  density: AeroDensity.compact,
                  onPressed: () => _confirmClearHistory(ctx),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<_SettingItemSpec> _getAppearanceSpecs() {
    return [
      _SettingItemSpec(
        id: 'theme_mode',
        title: 'Theme Mode',
        description: 'System, Light, Dark, or pure-black AMOLED theme',
        keywords: [
          'dark',
          'light',
          'oled',
          'amoled',
          'black',
          'battery',
          'system',
          'mode',
          'color',
          'theme',
        ],
        builder: (_) => const _ThemeSegmentedRow(),
      ),
      _SettingItemSpec(
        id: 'enable_animations',
        title: 'Enable Animations',
        description: 'Linear transitions and loading animations',
        keywords: ['motion', 'transitions', 'reduce motion', 'animation'],
        builder: (_) => _SettingsSwitchRow(
          title: 'Enable Animations',
          subtitle: 'Linear transitions and loading animations',
          icon: Symbols.animation_rounded,
          selector: (p) => p.enableAnimations,
          onChanged: (p, v) => p.setEnableAnimations(v),
        ),
      ),
      _SettingItemSpec(
        id: 'interface_density',
        title: 'Interface Density',
        description: PlatformUtils.isMobile
            ? 'Comfortable (Optimized for touch)'
            : 'Compact (Optimized for pointer & keyboard)',
        keywords: [
          'density',
          'compact',
          'comfortable',
          'touch',
          'scale',
          'size',
        ],
        builder: (_) => SettingsRow(
          title: 'Interface Density',
          subtitle: PlatformUtils.isMobile
              ? 'Comfortable (Optimized for touch)'
              : 'Compact (Optimized for pointer & keyboard)',
          icon: Symbols.density_medium_rounded,
          trailing: StatusPill.info(
            label: PlatformUtils.isMobile ? 'Comfortable' : 'Compact',
          ),
        ),
      ),
    ];
  }

  List<_SettingItemSpec> _getToolsSpecs() {
    return [
      _SettingItemSpec(
        id: 'tool_ytdlp',
        title: 'yt-dlp',
        description: 'Core video download engine',
        keywords: [
          'ytdlp',
          'binary',
          'version',
          'update',
          'downloader',
          'core',
        ],
        builder: (_) => _ToolStatusRow(host: this, isYtdlp: true),
      ),
      _SettingItemSpec(
        id: 'tool_ffmpeg',
        title: 'FFmpeg',
        description: 'Media stream merge and format conversion engine',
        keywords: [
          'ffmpeg',
          'binary',
          'version',
          'update',
          'muxer',
          'audio',
          'convert',
        ],
        builder: (_) => _ToolStatusRow(host: this, isYtdlp: false),
      ),
    ];
  }

  List<_SettingItemSpec> _getBackgroundSpecs(
    ({
      bool isAndroid,
      bool enableCookies,
      bool isYouTubeLoggedIn,
      bool isAggressiveOem,
    })
    visibility,
  ) {
    return [
      _SettingItemSpec(
        id: 'download_notifications',
        title: 'Download Notifications',
        description: 'Show system alerts on download progress and completion',
        keywords: ['alerts', 'push', 'notifications', 'tray', 'background'],
        builder: (_) => _SettingsSwitchRow(
          title: 'Download Notifications',
          subtitle: 'Show system alerts on download progress and completion',
          icon: Symbols.notifications_rounded,
          selector: (p) => p.enableNotifications,
          onChanged: (p, v) => p.setEnableNotifications(v),
        ),
      ),
      _SettingItemSpec(
        id: 'sponsorblock',
        title: 'SponsorBlock',
        description:
            'Automatically skip sponsored segments and non-music sections',
        keywords: [
          'skip',
          'sponsors',
          'segments',
          'intro',
          'outro',
          'sponsorblock',
        ],
        builder: (_) => _SettingsSwitchRow(
          title: 'SponsorBlock',
          subtitle:
              'Automatically skip sponsored segments and non-music sections',
          icon: Symbols.skip_next_rounded,
          selector: (p) => p.sponsorBlockEnabled,
          onChanged: (p, v) => p.setSponsorBlockEnabled(v),
        ),
      ),
      if (visibility.isAndroid)
        _SettingItemSpec(
          id: 'unrestricted_battery',
          title: 'Unrestricted Battery',
          description: 'Allow background downloads when the screen is locked',
          keywords: ['battery', 'unrestricted', 'doze', 'pause', 'screen off'],
          builder: (_) => _BatteryOptimizationRow(host: this),
        ),
      if (visibility.isAndroid && visibility.isAggressiveOem)
        _SettingItemSpec(
          id: 'oem_autostart',
          title: 'OEM Autostart Settings',
          description: 'Configure device-specific background whitelist',
          keywords: [
            'autostart',
            'xiaomi',
            'samsung',
            'oppo',
            'vivo',
            'huawei',
          ],
          builder: (_) => const _OemAutostartRow(),
        ),
      _SettingItemSpec(
        id: 'download_archive',
        title: 'Download Archive',
        description: 'Track downloaded video IDs to avoid duplicate downloads',
        keywords: [
          'archive',
          'duplicate',
          'history',
          're-download',
          'skip existing',
        ],
        builder: (_) => _SettingsSwitchRow(
          title: 'Download Archive',
          subtitle: 'Track downloaded video IDs to avoid duplicate downloads',
          icon: Symbols.history_rounded,
          selector: (p) => p.useDownloadArchive,
          onChanged: (p, v) => p.setUseDownloadArchive(v),
        ),
      ),
    ];
  }

  List<_SettingItemSpec> _getAdvancedSpecs() {
    return [
      _SettingItemSpec(
        id: 'component_gallery',
        title: 'Component Gallery',
        description: 'Interactive catalog of all Aero design system widgets',
        keywords: ['components', 'gallery', 'design', 'tokens', 'debug', 'ui'],
        builder: (ctx) => SettingsRow(
          title: 'Component Gallery',
          subtitle: 'Interactive catalog of all Aero design system widgets',
          icon: Symbols.widgets_rounded,
          onTap: () => Navigator.push(
            ctx,
            MaterialPageRoute(builder: (_) => const ComponentGalleryScreen()),
          ),
        ),
      ),
      _SettingItemSpec(
        id: 'view_logs',
        title: 'View Logs',
        description: 'Developer debugging logs and runtime events',
        keywords: ['logs', 'view', 'console', 'debug', 'errors', 'terminal'],
        builder: (ctx) => SettingsRow(
          title: 'View Logs',
          subtitle: 'Developer debugging logs and runtime events',
          icon: Symbols.receipt_long_rounded,
          onTap: () => _showLogsViewer(ctx),
        ),
      ),
      _SettingItemSpec(
        id: 'export_logs',
        title: 'Export Logs',
        description: 'Save or copy app.log for troubleshooting',
        keywords: ['export', 'save logs', 'copy', 'file', 'share'],
        builder: (ctx) => SettingsRow(
          title: 'Export Logs',
          subtitle: 'Save or copy app.log for troubleshooting',
          icon: Symbols.file_download_rounded,
          onTap: () => _exportLogs(ctx),
        ),
      ),
      _SettingItemSpec(
        id: 'report_bug',
        title: 'Report a Bug',
        description: 'Compile diagnostic report to file on GitHub',
        keywords: ['bug', 'report', 'issue', 'github', 'crash', 'problem'],
        builder: (ctx) => SettingsRow(
          title: 'Report a Bug',
          subtitle: 'Compile diagnostic report to file on GitHub',
          icon: Symbols.pest_control_rounded,
          onTap: () => BugReportDialog.show(ctx),
        ),
      ),
      _SettingItemSpec(
        id: 'enable_logging',
        title: 'Enable Logging',
        description: 'Write debug information to file',
        keywords: ['logging', 'debug', 'trace', 'file'],
        builder: (_) => _SettingsSwitchRow(
          title: 'Enable Logging',
          subtitle: 'Write debug information to file',
          icon: Symbols.bug_report_rounded,
          selector: (p) => p.enableLogging,
          onChanged: (p, v) => p.setEnableLogging(v),
        ),
      ),
    ];
  }

  List<_SettingItemSpec> _getAboutSpecs() {
    return [
      _SettingItemSpec(
        id: 'check_updates',
        title: 'Check for Updates',
        description: 'Check for new AeroTube releases',
        keywords: ['update', 'version', 'github', 'download', 'upgrade'],
        builder: (_) => const _AppUpdateCheckRow(),
      ),
      _SettingItemSpec(
        id: 'auto_check_updates',
        title: 'Auto-check for Updates',
        description: 'Check automatically at app launch',
        keywords: ['auto check', 'startup', 'updates', 'automatic'],
        builder: (_) => const _AutoUpdateSwitchRow(),
      ),
    ];
  }

  Widget _buildToolRow(
    BuildContext context, {
    required String toolName,
    required IconData icon,
    required ToolUpdateState state,
    required String? version,
    required VoidCallback onCheckUpdate,
    VoidCallback? onUpdate,
    VoidCallback? onCancel,
    required VoidCallback onInstall,
    required VoidCallback onAdvanced,
  }) {
    String subtitle;
    StatusPill pill;

    if (state.isBusy) {
      subtitle = state.statusMessage ?? 'Operation in progress…';
      pill = const StatusPill(
        label: 'Updating…',
        type: StatusPillType.info,
        showSpinner: true,
      );
    } else if (state.status == ToolUpdateStatus.error) {
      subtitle = 'Error encountered. Tap to inspect.';
      pill = StatusPill.danger(
        label: 'Error',
        onTap: () {
          final parsed = ErrorHelper.parse(state.errorMessage ?? 'Tool error');
          ErrorDetailsDialog.show(
            context,
            error: parsed,
            customTitle: '$toolName Error',
            onRetry: onCheckUpdate,
          );
        },
      );
    } else if (state.hasUpdate) {
      subtitle = PlatformUtils.isMobile
          ? 'v${state.latestVersion} available'
          : 'New release available: v${state.latestVersion}';
      pill = StatusPill.warning(label: 'Update v${state.latestVersion}');
    } else if (state.currentVersion != null || version != null) {
      final v = state.currentVersion ?? version;
      subtitle = 'Installed: v$v';
      pill = StatusPill.success(label: 'v$v');
    } else {
      subtitle = 'Not installed or not detected';
      pill = const StatusPill.warning(label: 'Not installed');
    }

    Widget actionButton;
    if (state.isBusy) {
      actionButton = AeroButton.tonal(
        text: 'Cancel',
        height: 32,
        density: AeroDensity.compact,
        onPressed: onCancel,
      );
    } else if (state.hasUpdate) {
      actionButton = AeroButton.primary(
        text: 'Update',
        height: 32,
        density: AeroDensity.compact,
        onPressed: onUpdate,
      );
    } else if (!state.isAvailable) {
      actionButton = AeroButton.primary(
        text: 'Install',
        height: 32,
        density: AeroDensity.compact,
        onPressed: onInstall,
      );
    } else {
      actionButton = AeroButton.tonal(
        text: 'Check',
        height: 32,
        density: AeroDensity.compact,
        isLoading: state.status == ToolUpdateStatus.checking,
        onPressed: onCheckUpdate,
      );
    }

    return SettingsRow(
      title: toolName,
      subtitle: subtitle,
      icon: icon,
      padding: PlatformUtils.isMobile
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 12)
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!PlatformUtils.isMobile) ...[
            pill,
            const SizedBox(width: AeroSpace.sm),
            actionButton,
          ] else
            IconButton.filledTonal(
              tooltip: state.isBusy
                  ? 'Cancel $toolName update'
                  : state.hasUpdate
                  ? 'Update $toolName'
                  : !state.isAvailable
                  ? 'Install $toolName'
                  : 'Check $toolName for updates',
              onPressed: state.isBusy
                  ? onCancel
                  : state.hasUpdate
                  ? onUpdate
                  : !state.isAvailable
                  ? onInstall
                  : onCheckUpdate,
              icon: Icon(
                state.isBusy
                    ? Symbols.close_rounded
                    : state.hasUpdate
                    ? Symbols.system_update_alt_rounded
                    : !state.isAvailable
                    ? Symbols.download_rounded
                    : Symbols.refresh_rounded,
                size: 20,
              ),
            ),
          const SizedBox(width: AeroSpace.xs),
          IconButton(
            icon: const Icon(Symbols.more_vert_rounded, size: 18),
            tooltip: 'Advanced Settings',
            onPressed: onAdvanced,
          ),
        ],
      ),
    );
  }

  void _showBatteryHelpDialog(PlatformSettingsProvider provider) {
    showAeroDialog<void>(
      context: context,
      builder: (dialogContext) => AeroDialog(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: dialogContext.aero.danger.withValues(alpha: 0.15),
            borderRadius: AeroRadius.smBorderRadius,
          ),
          alignment: Alignment.center,
          child: Icon(
            Symbols.battery_alert_rounded,
            color: dialogContext.aero.danger,
            size: 20,
          ),
        ),
        titleText: 'Downloads May Pause',
        content: Text(
          'Your device did not grant unrestricted battery. To fix background paused downloads, locate AeroTube in your system battery optimization settings and choose "Unrestricted".',
          style: AeroText.bodySm.copyWith(
            color: dialogContext.aero.onSurfaceMuted,
          ),
        ),
        actions: [
          AeroButton.ghost(
            text: 'Later',
            density: AeroDensity.compact,
            onPressed: () => Navigator.pop(dialogContext),
          ),
          AeroButton.primary(
            text: 'Open Battery Settings',
            density: AeroDensity.compact,
            onPressed: () {
              Navigator.pop(dialogContext);
              provider.openBatteryOptimizationSettings();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAboutFooter(BuildContext context) {
    final colors = context.aero;

    return Center(
      child: Column(
        children: [
          const AppLogo(size: 72, useAnimations: false, showGlow: false),
          const SizedBox(height: AeroSpace.md),
          Text(
            'AeroTube v$_appVersion',
            style: AeroText.bodySm.copyWith(
              color: colors.onSurfaceMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AeroSpace.xs),
          Text(
            'Clean, focused media downloader',
            style: AeroText.caption.copyWith(color: colors.onSurfaceFaint),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // MODAL SHEETS & ACTIONS
  // =========================================================================

  Future<void> _confirmLogout(
    BuildContext context,
    PlatformSettingsProvider provider,
  ) async {
    final confirmed = await showAeroDialog<bool>(
      context: context,
      builder: (dialogContext) => AeroDialog(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: dialogContext.aero.danger.withValues(alpha: 0.15),
            borderRadius: AeroRadius.smBorderRadius,
          ),
          alignment: Alignment.center,
          child: Icon(
            Symbols.logout_rounded,
            color: dialogContext.aero.danger,
            size: 20,
          ),
        ),
        titleText: 'Log out of YouTube?',
        content: Text(
          'You will need to sign in again to download members-only or age-restricted videos.',
          style: AeroText.bodySm.copyWith(
            color: dialogContext.aero.onSurfaceMuted,
          ),
        ),
        actions: [
          AeroButton.ghost(
            text: 'Cancel',
            density: AeroDensity.compact,
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          AeroButton.danger(
            text: 'Log out',
            density: AeroDensity.compact,
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await provider.logoutFromYouTube();
      await provider.setCookieBrowser(null);
      if (context.mounted) {
        AeroSnack.info(context, message: 'Logged out of YouTube');
      }
    }
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final confirmed = await showAeroDialog<bool>(
      context: context,
      builder: (dialogContext) => AeroDialog(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: dialogContext.aero.danger.withValues(alpha: 0.15),
            borderRadius: AeroRadius.smBorderRadius,
          ),
          alignment: Alignment.center,
          child: Icon(
            Symbols.delete_rounded,
            color: dialogContext.aero.danger,
            size: 20,
          ),
        ),
        titleText: 'Clear Download History?',
        content: Text(
          'This will remove all downloaded entries from your history list. Files on disk will remain untouched.',
          style: AeroText.bodySm.copyWith(
            color: dialogContext.aero.onSurfaceMuted,
          ),
        ),
        actions: [
          AeroButton.ghost(
            text: 'Cancel',
            density: AeroDensity.compact,
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          AeroButton.danger(
            text: 'Clear history',
            density: AeroDensity.compact,
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      if (PlatformUtils.isMobile) {
        context.read<MobileDownloadProvider>().clearCompleted();
        context.read<MobileDownloadProvider>().clearFailed();
        context.read<MobileDownloadProvider>().clearCancelled();
      } else {
        await context.read<DownloadProvider>().clearHistory();
      }
      if (context.mounted) {
        AeroSnack.success(context, message: 'Download history cleared');
      }
    }
  }

  void _showQualitySheet(
    BuildContext context,
    PlatformSettingsProvider provider,
  ) {
    const qualities = ['Best', '4K', '1080p', '720p', '480p', 'Audio Only'];

    showAeroSheet(
      context: context,
      titleText: 'Default Download Quality',
      builder: (sheetContext) {
        final colors = sheetContext.aero;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: qualities.map((q) {
            final isSelected = provider.defaultQuality == q;
            return SettingsRow(
              title: q,
              icon: _getQualityIcon(q),
              trailing: isSelected
                  ? Icon(Symbols.check_rounded, color: colors.primary, size: 20)
                  : null,
              onTap: () {
                provider.setDefaultQuality(q);
                Navigator.pop(sheetContext);
              },
            );
          }).toList(),
        );
      },
    );
  }

  IconData _getQualityIcon(String quality) {
    switch (quality) {
      case 'Best':
        return Symbols.auto_awesome_rounded;
      case '4K':
        return Symbols.four_k_rounded;
      case '1080p':
        return Symbols.hd_rounded;
      case '720p':
      case '480p':
        return Symbols.sd_rounded;
      case 'Audio Only':
        return Symbols.audiotrack_rounded;
      default:
        return Symbols.high_quality_rounded;
    }
  }

  void _showDefaultSubtitleLanguageSheet(
    BuildContext context,
    PlatformSettingsProvider provider,
  ) {
    const subtitleLanguages = <Map<String, String>>[
      {'code': 'auto', 'label': 'Auto (Video Default)'},
      {'code': 'en', 'label': 'English'},
      {'code': 'ar', 'label': 'Arabic'},
      {'code': 'es', 'label': 'Spanish'},
      {'code': 'fr', 'label': 'French'},
      {'code': 'de', 'label': 'German'},
      {'code': 'it', 'label': 'Italian'},
      {'code': 'pt', 'label': 'Portuguese'},
      {'code': 'ru', 'label': 'Russian'},
      {'code': 'hi', 'label': 'Hindi'},
      {'code': 'tr', 'label': 'Turkish'},
      {'code': 'ja', 'label': 'Japanese'},
      {'code': 'ko', 'label': 'Korean'},
      {'code': 'zh', 'label': 'Chinese'},
    ];

    showAeroSheet(
      context: context,
      titleText: 'Default Subtitle Language',
      builder: (sheetContext) {
        final colors = sheetContext.aero;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: subtitleLanguages.map((lang) {
            final isSelected = provider.defaultSubtitleLanguage == lang['code'];
            return SettingsRow(
              title: lang['label']!,
              subtitle: lang['code'] == 'auto'
                  ? 'Pick first available subtitle stream automatically'
                  : 'Language code: ${lang['code']}',
              icon: _getSubtitleLanguageIcon(lang['code']!),
              trailing: isSelected
                  ? Icon(Symbols.check_rounded, color: colors.primary, size: 20)
                  : null,
              onTap: () {
                provider.setDefaultSubtitleLanguage(lang['code']!);
                Navigator.pop(sheetContext);
              },
            );
          }).toList(),
        );
      },
    );
  }

  String _subtitleLanguageLabel(String code) {
    const labels = <String, String>{
      'auto': 'Auto (Video Default)',
      'en': 'English',
      'ar': 'Arabic',
      'es': 'Spanish',
      'fr': 'French',
      'de': 'German',
      'it': 'Italian',
      'pt': 'Portuguese',
      'ru': 'Russian',
      'hi': 'Hindi',
      'tr': 'Turkish',
      'ja': 'Japanese',
      'ko': 'Korean',
      'zh': 'Chinese',
    };
    return labels[code] ?? code.toUpperCase();
  }

  IconData _getSubtitleLanguageIcon(String code) {
    if (code == 'auto') return Symbols.auto_awesome_rounded;
    if (code == 'ar') return Symbols.language_rounded;
    return Symbols.translate_rounded;
  }

  void _showBrowserSheet(
    BuildContext context,
    PlatformSettingsProvider provider,
  ) {
    const browsers = ['chrome', 'firefox', 'edge', 'opera', 'brave', 'vivaldi'];

    showAeroSheet(
      context: context,
      titleText: 'Select Browser for Cookies',
      builder: (sheetContext) {
        final colors = sheetContext.aero;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: browsers.map((b) {
            final isSelected = provider.settings.cookieBrowser == b;
            return SettingsRow(
              title: b[0].toUpperCase() + b.substring(1),
              icon: _getBrowserIcon(b),
              trailing: isSelected
                  ? Icon(Symbols.check_rounded, color: colors.primary, size: 20)
                  : null,
              onTap: () {
                provider.setCookieBrowser(b);
                Navigator.pop(sheetContext);
              },
            );
          }).toList(),
        );
      },
    );
  }

  String _getBrowserLabel(String? browser) {
    if (browser == null || browser.isEmpty) return 'Not selected';
    return browser[0].toUpperCase() + browser.substring(1);
  }

  IconData _getBrowserIcon(String browser) {
    switch (browser.toLowerCase()) {
      case 'chrome':
        return Symbols.public_rounded;
      case 'firefox':
        return Symbols.local_fire_department_rounded;
      case 'edge':
        return Symbols.open_in_browser_rounded;
      case 'opera':
        return Symbols.circle_rounded;
      case 'brave':
        return Symbols.shield_rounded;
      case 'vivaldi':
        return Symbols.apps_rounded;
      default:
        return Symbols.web_rounded;
    }
  }

  void _showToolAdvancedSheet(
    BuildContext context,
    PlatformSettingsProvider provider,
    ToolUpdateProvider toolProvider,
    String toolName,
  ) {
    final isYtdlp = toolName == 'yt-dlp';
    final currentPath = isYtdlp
        ? provider.activeYtdlpPath
        : (provider.activeFfmpegPath ?? 'System PATH');

    final toolState = isYtdlp
        ? toolProvider.ytdlpState
        : toolProvider.ffmpegState;
    final currentVersion = toolState.currentVersion;
    final latestVersion = toolState.latestVersion;

    showAeroSheet(
      context: context,
      titleText: '$toolName Configuration',
      builder: (sheetContext) {
        final colors = sheetContext.aero;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(AeroSpace.md),
              decoration: BoxDecoration(
                color: colors.surface2,
                borderRadius: AeroRadius.mdBorderRadius,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Installed Path:',
                    style: AeroText.caption.copyWith(
                      color: colors.onSurfaceMuted,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currentPath,
                    style: AeroText.bodySm.copyWith(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Version: ${currentVersion ?? "Unknown"} (Latest: ${latestVersion ?? "Unknown"})',
                    style: AeroText.caption.copyWith(
                      color: colors.onSurfaceMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AeroSpace.md),
            SettingsRow(
              title: 'Download / Reinstall',
              subtitle: 'Download latest official release binary',
              icon: Symbols.download_for_offline_rounded,
              onTap: () {
                Navigator.pop(sheetContext);
                if (isYtdlp) {
                  toolProvider.installYtdlp();
                } else {
                  toolProvider.installFfmpeg();
                }
              },
            ),
            if (PlatformUtils.isWindows)
              SettingsRow(
                title: 'Select Custom Binary',
                subtitle: 'Choose custom executable path (.exe)',
                icon: Symbols.file_open_rounded,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final result = await FilePicker.pickFile(
                    type: FileType.custom,
                    allowedExtensions: ['exe'],
                  );
                  if (result?.path != null) {
                    if (isYtdlp) {
                      await provider.setYtdlpPath(result!.path);
                    } else {
                      await provider.setFfmpegPath(result!.path);
                    }
                    await toolProvider.refreshAvailability();
                  }
                },
              ),
            SettingsRow(
              title: 'Reset to Managed',
              subtitle: 'Restore application default managed binary',
              icon: Symbols.restart_alt_rounded,
              onTap: () async {
                Navigator.pop(sheetContext);
                if (isYtdlp) {
                  await provider.setYtdlpPath(null);
                } else {
                  await provider.setFfmpegPath(null);
                }
                await toolProvider.refreshAvailability();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportLogs(BuildContext context) async {
    final service = LoggingService();

    try {
      // ignore: deprecated_member_use
      final pickedPath = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select folder to export logs',
      );

      if (pickedPath == null || !context.mounted) return;

      if (PlatformUtils.isAndroid) {
        final validation = await AndroidStorageService()
            .validateCustomDirectory(pickedPath);
        if (!context.mounted) return;
        if (!validation.ok) {
          AeroSnack.warning(
            context,
            message: validation.reason ?? 'Folder not usable.',
          );
          return;
        }
      }

      final exportedPath = await service.exportLogsToFile(pickedPath);
      if (context.mounted) {
        AeroSnack.success(context, message: 'Logs saved to $exportedPath');
      }
    } catch (e) {
      if (PlatformUtils.isMobile) {
        try {
          final copiedText = service.exportLogs();
          if (copiedText.trim().isNotEmpty) {
            await Clipboard.setData(ClipboardData(text: copiedText));
            if (context.mounted) {
              AeroSnack.info(context, message: 'Logs copied to clipboard');
            }
            return;
          }
        } catch (_) {}
      }
      if (context.mounted) {
        AeroSnack.error(context, message: 'Failed to export logs: $e');
      }
    }
  }

  void _showLogsViewer(BuildContext context) {
    final windowHeight = MediaQuery.sizeOf(context).height;
    final desktopPanelHeight = (windowHeight - 180)
        .clamp(220.0, 640.0)
        .toDouble();

    if (PlatformUtils.isDesktop) {
      showAeroDialog<void>(
        context: context,
        builder: (_) => AeroDialog(
          maxWidth: 920,
          titleText: 'Runtime Logs',
          showCloseButton: true,
          content: SizedBox(
            height: desktopPanelHeight,
            child: const LogsViewer(showTitle: false),
          ),
        ),
      );
      return;
    }

    showAeroSheet<void>(
      context: context,
      titleText: 'Runtime Logs',
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.72,
        child: const LogsViewer(showTitle: false),
      ),
    );
  }
}

/// Storage permission tile for Android
class _AndroidStoragePermissionTile extends StatefulWidget {
  const _AndroidStoragePermissionTile({required this.provider});

  final PlatformSettingsProvider provider;

  @override
  State<_AndroidStoragePermissionTile> createState() =>
      _AndroidStoragePermissionTileState();
}

class _AndroidStoragePermissionTileState
    extends State<_AndroidStoragePermissionTile>
    with WidgetsBindingObserver {
  bool _granted = true;
  bool _checking = true;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _checking = true);
    try {
      final storage = AndroidStorageService();
      final granted = await storage.hasStoragePermission();
      if (!mounted) return;
      setState(() {
        _granted = granted;
        _checking = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _checking = false);
    }
  }

  Future<void> _request() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      final storage = AndroidStorageService();
      await storage.requestStoragePermission();
      if (!mounted) return;
      final granted = await storage.hasStoragePermission();
      if (!granted) {
        await storage.openManageStorageSettings();
      }
      await _refresh();
      if (mounted && _granted) {
        try {
          final preferred = await storage.getPreferredDownloadDirectory();
          if (preferred != widget.provider.outputPath) {
            await widget.provider.setOutputPath(preferred);
          }
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _requesting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _granted ? 'Storage Access' : 'Grant Storage Access';
    final subtitle = _checking
        ? 'Checking permission…'
        : _granted
        ? 'Public Downloads folder is writable'
        : 'Allow All files access so downloads save to Downloads/AeroTube';

    return SettingsRow(
      title: title,
      subtitle: subtitle,
      icon: _granted
          ? Symbols.sd_storage_rounded
          : Symbols.warning_amber_rounded,
      iconColor: _granted ? context.aero.primary : Colors.amber.shade700,
      trailing: (_requesting || _checking)
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : StatusPill(
              label: _granted ? 'Granted' : 'Action Required',
              type: _granted ? StatusPillType.success : StatusPillType.warning,
            ),
      onTap: _requesting ? null : _request,
    );
  }
}

/// Debounced concurrency control with Aero slider styling
class _ConcurrentDownloadsControl extends StatefulWidget {
  const _ConcurrentDownloadsControl();

  @override
  State<_ConcurrentDownloadsControl> createState() =>
      _ConcurrentDownloadsControlState();
}

class _ConcurrentDownloadsControlState
    extends State<_ConcurrentDownloadsControl> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final persisted = context.select<PlatformSettingsProvider, int>(
      (p) => p.maxConcurrentDownloads,
    );
    final displayed = (_dragValue ?? persisted.toDouble()).clamp(1.0, 6.0);
    final colors = context.aero;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AeroSpace.lg,
        vertical: AeroSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.surface2,
                  borderRadius: AeroRadius.smBorderRadius,
                  border: Border.all(color: colors.outline, width: 1.0),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Symbols.downloading_rounded,
                  size: 20,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(width: AeroSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Concurrent Downloads',
                      style: AeroText.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${displayed.toInt()} simultaneous active downloads',
                      style: AeroText.bodySm.copyWith(
                        color: colors.onSurfaceMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AeroSpace.sm),
          Padding(
            padding: const EdgeInsets.only(left: 48, right: 8),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: colors.primary,
                inactiveTrackColor: colors.surface3,
                thumbColor: colors.primary,
                overlayColor: colors.primaryGlow,
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: displayed,
                min: 1,
                max: 6,
                divisions: 5,
                label: '${displayed.toInt()}',
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) {
                  setState(() => _dragValue = null);
                  context
                      .read<PlatformSettingsProvider>()
                      .setMaxConcurrentDownloads(v.toInt());
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
