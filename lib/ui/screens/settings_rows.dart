part of 'settings_screen.dart';

/// Lightweight metadata descriptor for a single setting row.
/// [matches] filters on title, description, and keywords BEFORE [builder]
/// is ever invoked, avoiding eager widget construction for hidden/filtered rows.
class _SettingItemSpec {
  final String id;
  final String title;
  final String? description;
  final List<String> keywords;
  final WidgetBuilder builder;

  const _SettingItemSpec({
    required this.id,
    required this.title,
    this.description,
    this.keywords = const [],
    required this.builder,
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    if (title.toLowerCase().contains(q)) return true;
    if (description != null && description!.toLowerCase().contains(q)) {
      return true;
    }
    for (final kw in keywords) {
      if (kw.toLowerCase().contains(q)) return true;
    }
    return false;
  }
}

sealed class _LazySettingsRow {
  const _LazySettingsRow();
  String get id;
  Widget build(BuildContext context);
}

class _WidgetSettingsRow extends _LazySettingsRow {
  @override
  final String id;
  final WidgetBuilder builder;
  const _WidgetSettingsRow(this.id, this.builder);
  @override
  Widget build(BuildContext context) => builder(context);
}

class _SectionHeaderSettingsRow extends _LazySettingsRow {
  final String title;
  const _SectionHeaderSettingsRow(this.title);
  @override
  String get id => 'section_$title';
  @override
  Widget build(BuildContext context) => SectionHeader(title: title);
}

class _CardItemSettingsRow extends _LazySettingsRow {
  final _SettingItemSpec spec;
  final bool isFirst;
  final bool isLast;

  const _CardItemSettingsRow({
    required this.spec,
    required this.isFirst,
    required this.isLast,
  });

  @override
  String get id => spec.id;

  @override
  Widget build(BuildContext context) {
    final colors = context.aero;
    const r = Radius.circular(AeroRadius.lg);
    final borderRadius = BorderRadius.only(
      topLeft: isFirst ? r : Radius.zero,
      topRight: isFirst ? r : Radius.zero,
      bottomLeft: isLast ? r : Radius.zero,
      bottomRight: isLast ? r : Radius.zero,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface1,
        borderRadius: borderRadius,
        border: Border(
          top: isFirst
              ? BorderSide(color: colors.outline, width: 1.0)
              : BorderSide.none,
          bottom: isLast
              ? BorderSide(color: colors.outline, width: 1.0)
              : BorderSide.none,
          left: BorderSide(color: colors.outline, width: 1.0),
          right: BorderSide(color: colors.outline, width: 1.0),
        ),
      ),
      // Only the two rounded ends of a section need a clipping layer.
      // Interior rows have square edges and can paint directly.
      child: ClipRRect(
        borderRadius: borderRadius,
        clipBehavior: isFirst || isLast ? Clip.antiAlias : Clip.none,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!isFirst)
              Divider(
                height: 1,
                thickness: 1,
                indent: 56,
                color: colors.outline,
              ),
            KeyedSubtree(
              key: ValueKey('setting_row_${spec.id}'),
              child: spec.builder(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings has a small, bounded number of rows. Keep each row after its first
/// visit, without eagerly building the entire page. This avoids repeated text
/// layout, controller creation and Android permission checks on return scrolls.
class _RetainedSettingsRow extends StatefulWidget {
  final _LazySettingsRow row;

  const _RetainedSettingsRow({super.key, required this.row});

  @override
  State<_RetainedSettingsRow> createState() => _RetainedSettingsRowState();
}

class _RetainedSettingsRowState extends State<_RetainedSettingsRow>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.row.build(context);
  }
}

/// Reusable switch row subscribing only to its own boolean setting.
class _SettingsSwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool Function(PlatformSettingsProvider p) selector;
  final Future<void> Function(PlatformSettingsProvider p, bool value) onChanged;

  const _SettingsSwitchRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selector,
    required this.onChanged,
  });

  Future<void> _handleChange(BuildContext context, bool next) async {
    final provider = context.read<PlatformSettingsProvider>();
    try {
      await onChanged(provider, next);
    } catch (_) {
      if (context.mounted) {
        AeroSnack.error(context, message: 'Could not save "$title". Reverted.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = context.select<PlatformSettingsProvider, bool>(selector);
    final colors = context.aero;
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      trailing: Switch.adaptive(
        value: value,
        activeThumbColor: colors.primary,
        activeTrackColor: colors.primarySoft,
        onChanged: (v) => _handleChange(context, v),
      ),
      onTap: () => _handleChange(context, !value),
    );
  }
}

class _AccountStatusRow extends StatelessWidget {
  const _AccountStatusRow();

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<
          PlatformSettingsProvider,
          ({bool isSignedIn, bool cookiesReady, bool enableCookies})
        >(
          (p) => (
            isSignedIn: p.isYouTubeLoggedIn,
            cookiesReady: p.isCookieActive,
            enableCookies: p.enableCookies,
          ),
        );

    final statusLabel = state.isSignedIn
        ? 'Signed in'
        : state.cookiesReady
        ? 'Cookies ready'
        : 'Guest';
    final statusSubtitle = state.isSignedIn
        ? state.enableCookies
              ? 'YouTube session ready'
              : 'Signed in · cookies are off'
        : state.cookiesReady
        ? 'Cookie source ready'
        : 'Optional for members-only videos';

    return SettingsRow(
      title: 'Account Status',
      subtitle: statusSubtitle,
      icon: state.isSignedIn || state.cookiesReady
          ? Symbols.lock_open_rounded
          : Symbols.lock_rounded,
      iconColor: state.isSignedIn || state.cookiesReady ? Colors.green : null,
      trailing: StatusPill(
        label: statusLabel,
        type: state.isSignedIn || state.cookiesReady
            ? StatusPillType.success
            : StatusPillType.neutral,
      ),
    );
  }
}

class _BrowserCookiesRow extends StatelessWidget {
  final _SettingsScreenState host;
  const _BrowserCookiesRow({required this.host});

  @override
  Widget build(BuildContext context) {
    final browser = context.select<PlatformSettingsProvider, String?>(
      (p) => p.settings.cookieBrowser,
    );
    return SettingsRow(
      title: 'Browser Cookies',
      subtitle: host._getBrowserLabel(browser),
      icon: Symbols.cookie_rounded,
      onTap: () => host._showBrowserSheet(
        context,
        context.read<PlatformSettingsProvider>(),
      ),
    );
  }
}

class _ImportCookiesRow extends StatelessWidget {
  const _ImportCookiesRow();

  @override
  Widget build(BuildContext context) {
    final fileName = context.select<PlatformSettingsProvider, String?>(
      (p) => p.cookieFileName,
    );
    return SettingsRow(
      title: 'Import cookies.txt',
      subtitle: fileName ?? 'No file selected',
      icon: Symbols.upload_file_rounded,
      onTap: () async {
        final result = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['txt'],
        );
        if (result?.path != null && context.mounted) {
          await context.read<PlatformSettingsProvider>().setCookiePath(
            result!.path,
          );
        }
      },
    );
  }
}

class _DownloadLocationRow extends StatelessWidget {
  const _DownloadLocationRow();

  @override
  Widget build(BuildContext context) {
    final outputPath = context.select<PlatformSettingsProvider, String?>(
      (p) => p.outputPath,
    );
    return SettingsRow(
      title: 'Download Location',
      subtitle: outputPath ?? 'Default folder',
      icon: Symbols.folder_rounded,
      onTap: () async {
        // ignore: deprecated_member_use
        final result = await FilePicker.getDirectoryPath();
        if (result == null || !context.mounted) return;
        final provider = context.read<PlatformSettingsProvider>();

        if (provider.isAndroid) {
          final validation = await AndroidStorageService()
              .validateCustomDirectory(result);
          if (!context.mounted) return;
          if (!validation.ok) {
            AeroSnack.warning(
              context,
              message: validation.reason ?? 'Folder not usable.',
            );
            return;
          }
        }

        await provider.setOutputPath(result);
        if (context.mounted) {
          AeroSnack.success(context, message: 'Download folder updated');
        }
      },
    );
  }
}

class _DefaultQualityRow extends StatelessWidget {
  final _SettingsScreenState host;
  const _DefaultQualityRow({required this.host});

  @override
  Widget build(BuildContext context) {
    final quality = context.select<PlatformSettingsProvider, String>(
      (p) => p.defaultQuality,
    );
    final colors = context.aero;
    return SettingsRow(
      title: 'Default Quality',
      subtitle: quality,
      icon: Symbols.high_quality_rounded,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            quality,
            style: AeroText.bodySm.copyWith(
              color: colors.onSurfaceMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Symbols.chevron_right_rounded,
            size: 20,
            color: colors.onSurfaceMuted,
          ),
        ],
      ),
      onTap: () => host._showQualitySheet(
        context,
        context.read<PlatformSettingsProvider>(),
      ),
    );
  }
}

class _DefaultSubtitleRow extends StatelessWidget {
  final _SettingsScreenState host;
  const _DefaultSubtitleRow({required this.host});

  @override
  Widget build(BuildContext context) {
    final code = context.select<PlatformSettingsProvider, String>(
      (p) => p.defaultSubtitleLanguage,
    );
    final label = host._subtitleLanguageLabel(code);
    return SettingsRow(
      title: 'Default Subtitle Language',
      subtitle: label,
      icon: Symbols.subtitles_rounded,
      onTap: () => host._showDefaultSubtitleLanguageSheet(
        context,
        context.read<PlatformSettingsProvider>(),
      ),
    );
  }
}

class _ThemeSegmentedRow extends StatelessWidget {
  const _ThemeSegmentedRow();

  @override
  Widget build(BuildContext context) {
    final themeState = context
        .select<
          PlatformSettingsProvider,
          ({ThemeMode themeMode, bool amoledDark})
        >((p) => (themeMode: p.themeMode, amoledDark: p.amoledDark));
    final current = themeState.themeMode;
    final amoledSelected = themeState.amoledDark && current == ThemeMode.dark;
    final provider = context.read<PlatformSettingsProvider>();

    final chips = <Widget>[
      AeroChip(
        text: 'Auto',
        icon: const Icon(Symbols.auto_mode_rounded),
        selected: current == ThemeMode.system,
        onTap: () {
          provider.setAmoledDark(false);
          provider.setThemeMode(ThemeMode.system);
        },
      ),
      AeroChip(
        text: 'Light',
        icon: const Icon(Symbols.light_mode_rounded),
        selected: current == ThemeMode.light,
        onTap: () {
          provider.setAmoledDark(false);
          provider.setThemeMode(ThemeMode.light);
        },
      ),
      AeroChip(
        text: 'Dark',
        icon: const Icon(Symbols.dark_mode_rounded),
        selected: current == ThemeMode.dark && !amoledSelected,
        onTap: () {
          provider.setAmoledDark(false);
          provider.setThemeMode(ThemeMode.dark);
        },
      ),
      AeroChip(
        text: 'AMOLED',
        icon: const Icon(Symbols.contrast_rounded),
        selected: amoledSelected,
        onTap: () {
          provider.setThemeMode(ThemeMode.dark);
          provider.setAmoledDark(true);
        },
      ),
    ];

    final String description;
    if (amoledSelected) {
      description =
          'Pure black background — saves battery on OLED/AMOLED screens.';
    } else if (current == ThemeMode.system) {
      description = 'Follows your device theme setting.';
    } else if (current == ThemeMode.light) {
      description = 'Always uses the light palette.';
    } else {
      description = 'Deep navy greys that are easier on the eyes at night.';
    }

    return Padding(
      padding: const EdgeInsets.all(AeroSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: context.aero.surface2,
                  borderRadius: AeroRadius.smBorderRadius,
                  border: Border.all(color: context.aero.outline, width: 1.0),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Symbols.palette_rounded,
                  size: 20,
                  color: context.aero.onSurface,
                ),
              ),
              const SizedBox(width: AeroSpace.md),
              Text(
                'Theme Mode',
                style: AeroText.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: AeroSpace.md),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 440) {
                return Wrap(
                  spacing: AeroSpace.sm,
                  runSpacing: AeroSpace.sm,
                  children: chips,
                );
              }
              return Row(
                children: [
                  for (var i = 0; i < chips.length; i++) ...[
                    if (i > 0) const SizedBox(width: AeroSpace.sm),
                    Expanded(child: chips[i]),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: AeroSpace.sm),
          Text(
            description,
            style: AeroText.caption.copyWith(
              color: context.aero.onSurfaceMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolStatusRow extends StatelessWidget {
  final _SettingsScreenState host;
  final bool isYtdlp;

  const _ToolStatusRow({required this.host, required this.isYtdlp});

  @override
  Widget build(BuildContext context) {
    final state = context.select<ToolUpdateProvider, ToolUpdateState>(
      (p) => isYtdlp ? p.ytdlpState : p.ffmpegState,
    );
    final version = context.select<PlatformSettingsProvider, String?>(
      (p) => isYtdlp ? p.ytdlpVersion : p.ffmpegVersion,
    );
    final toolProvider = context.read<ToolUpdateProvider>();
    final settingsProvider = context.read<PlatformSettingsProvider>();

    return host._buildToolRow(
      context,
      toolName: isYtdlp ? 'yt-dlp' : 'FFmpeg',
      icon: isYtdlp ? Symbols.terminal_rounded : Symbols.video_settings_rounded,
      state: state,
      version: version,
      onCheckUpdate: () => isYtdlp
          ? toolProvider.checkYtdlpForUpdate(force: true)
          : toolProvider.checkFfmpegForUpdate(force: true),
      onUpdate: state.hasUpdate
          ? () => isYtdlp
                ? toolProvider.updateYtdlp()
                : toolProvider.updateFfmpeg()
          : null,
      onCancel: state.isBusy
          ? () => isYtdlp
                ? toolProvider.cancelYtdlpUpdate()
                : toolProvider.cancelFfmpegUpdate()
          : null,
      onInstall: () =>
          isYtdlp ? toolProvider.installYtdlp() : toolProvider.installFfmpeg(),
      onAdvanced: () => host._showToolAdvancedSheet(
        context,
        settingsProvider,
        toolProvider,
        isYtdlp ? 'yt-dlp' : 'FFmpeg',
      ),
    );
  }
}

class _BatteryOptimizationRow extends StatelessWidget {
  final _SettingsScreenState host;
  const _BatteryOptimizationRow({required this.host});

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<PlatformSettingsProvider, ({bool isExempt, bool isChecking})>(
          (p) => (
            isExempt: p.isBatteryOptimizationIgnored,
            isChecking: p.isCheckingBatteryOptimization,
          ),
        );

    return SettingsRow(
      title: 'Unrestricted Battery',
      subtitle: state.isExempt
          ? 'Allowed — downloads continue when the screen is locked'
          : 'Restricted — system may suspend downloads when screen turns off. Tap to allow.',
      icon: state.isExempt
          ? Symbols.battery_charging_full_rounded
          : Symbols.battery_alert_rounded,
      iconColor: state.isExempt ? Colors.green : Colors.orange,
      trailing: state.isChecking
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : StatusPill(
              label: state.isExempt ? 'Allowed' : 'Restricted',
              type: state.isExempt
                  ? StatusPillType.success
                  : StatusPillType.warning,
            ),
      onTap: state.isChecking
          ? null
          : () async {
              final provider = context.read<PlatformSettingsProvider>();
              final granted = await provider
                  .requestBatteryOptimizationExemption();
              if (!context.mounted) return;
              if (granted) {
                AeroSnack.success(
                  context,
                  message: 'Unrestricted battery allowed',
                );
              } else {
                host._showBatteryHelpDialog(provider);
              }
            },
    );
  }
}

class _OemAutostartRow extends StatelessWidget {
  const _OemAutostartRow();

  @override
  Widget build(BuildContext context) {
    final manufacturer = context.select<PlatformSettingsProvider, String?>(
      (p) => p.deviceManufacturer,
    );
    return SettingsRow(
      title: '${manufacturer ?? "OEM"} Autostart Settings',
      subtitle: 'Configure device-specific background whitelist',
      icon: Symbols.power_settings_new_rounded,
      trailing: const Icon(Symbols.open_in_new_rounded, size: 18),
      onTap: () =>
          context.read<PlatformSettingsProvider>().openOemAutostartSettings(),
    );
  }
}

class _AppUpdateCheckRow extends StatelessWidget {
  const _AppUpdateCheckRow();

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<
          UpdateProvider,
          ({bool hasUpdate, bool isChecking, String? version})
        >(
          (p) => (
            hasUpdate: p.hasUpdate,
            isChecking: p.isChecking,
            version: p.updateInfo?.version,
          ),
        );
    return SettingsRow(
      title: 'Check for Updates',
      subtitle: state.hasUpdate
          ? 'Version ${state.version} available'
          : 'Check for new AeroTube releases',
      icon: Symbols.system_update_rounded,
      trailing: state.isChecking
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : state.hasUpdate
          ? const StatusPill.warning(label: 'Update Available')
          : const Icon(Symbols.chevron_right_rounded, size: 20),
      onTap: state.isChecking
          ? null
          : () async {
              final updateProvider = context.read<UpdateProvider>();
              await updateProvider.checkForUpdates(force: true);
              if (!context.mounted) return;
              if (updateProvider.status == UpdateStatus.available ||
                  updateProvider.status == UpdateStatus.upToDate ||
                  updateProvider.status == UpdateStatus.error) {
                showAeroDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const UpdateDialog(),
                );
              }
            },
    );
  }
}

class _AutoUpdateSwitchRow extends StatelessWidget {
  const _AutoUpdateSwitchRow();

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<UpdateProvider, bool>(
      (p) => p.autoCheckEnabled,
    );
    final colors = context.aero;
    return SettingsRow(
      title: 'Auto-check for Updates',
      subtitle: 'Check automatically at app launch',
      icon: Symbols.update_rounded,
      trailing: Switch.adaptive(
        value: enabled,
        activeThumbColor: colors.primary,
        activeTrackColor: colors.primarySoft,
        onChanged: (val) =>
            context.read<UpdateProvider>().setAutoCheckEnabled(val),
      ),
      onTap: () => context.read<UpdateProvider>().setAutoCheckEnabled(!enabled),
    );
  }
}
