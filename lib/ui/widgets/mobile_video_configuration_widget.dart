import 'package:material_symbols_icons/symbols.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/tokens/colors.dart';
import '../../core/theme/tokens/radius.dart';
import '../../core/theme/tokens/spacing.dart';
import '../../core/theme/tokens/typography.dart';
import '../../models/download_item.dart';
import '../../models/video_info.dart';
import '../../providers/mobile_download_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/platform_settings_provider.dart';
import '../../providers/video_provider.dart';
import '../components/components.dart';
import 'video_configuration_controls.dart';
import 'video_fetch_loading.dart';

/// Full-screen Android video configuration panel conforming to AeroTube redesign spec.
///
/// Features:
/// - Collapsing header with 16:9 [ThumbnailTile] and bottom gradient scrim overlay
///   (title, channel, duration chip).
/// - Video and Audio modes with animated quality controls.
/// - Wrapping [FormatChip] grid with estimated size under each label.
/// - Codec variant selection with HDR and 60fps tags.
/// - Collapsible "More options" accordion ([SettingsRow]s for container, subtitles, SponsorBlock, trim).
/// - Sticky bottom action bar: "Download · 142 MB" (primary, full width) + destination folder ghost button.
class MobileVideoConfigurationWidget extends StatefulWidget {
  final Future<void> Function() onDownload;
  final VoidCallback? onClear;

  const MobileVideoConfigurationWidget({
    super.key,
    required this.onDownload,
    this.onClear,
  });

  @override
  State<MobileVideoConfigurationWidget> createState() =>
      _MobileVideoConfigurationWidgetState();
}

class _MobileVideoConfigurationWidgetState
    extends State<MobileVideoConfigurationWidget> {
  bool _optionsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final videoProvider = context.watch<VideoProvider>();
    final aero = context.aero;

    if (videoProvider.isLoading) {
      return _buildLoadingState(context, aero, videoProvider);
    }

    if (videoProvider.hasError) {
      return _buildErrorState(context, aero, videoProvider);
    }

    final video = videoProvider.videoInfo;
    if (video == null || !videoProvider.hasVideo) {
      return const SizedBox.shrink();
    }

    return Scaffold(
      backgroundColor: aero.bg,
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              // 1. Collapsing 16:9 Header with scrim overlay
              _buildCollapsingHeader(context, aero, videoProvider, video),

              // 2. Configuration Body
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AeroSpace.xl,
                    AeroSpace.lg,
                    AeroSpace.xl,
                    140, // Bottom padding so sticky bar never clips content
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DownloadModeControls(
                        isAudio: videoProvider.audioOnly,
                        onChanged: videoProvider.setAudioOnly,
                        qualityOptions: videoProvider.audioOnly
                            ? AudioQualityConfigurationSection(
                                provider: videoProvider,
                                horizontalScrollTiers: true,
                              )
                            : _buildVideoQualitySection(
                                context,
                                aero,
                                videoProvider,
                              ),
                      ),
                      const SizedBox(height: AeroSpace.xl),

                      // Collapsible "More options" accordion
                      _buildOptionsAccordion(
                        context,
                        aero,
                        videoProvider,
                        video,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Sticky Bottom Action Bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildStickyBottomBar(context, aero, videoProvider, video),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // 1. Collapsing 16:9 Header
  // ==========================================

  Widget _buildCollapsingHeader(
    BuildContext context,
    AeroColors aero,
    VideoProvider provider,
    VideoInfo video,
  ) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final headerHeight = screenWidth * 9 / 16;

    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: headerHeight,
      backgroundColor: aero.surface1,
      elevation: 0,
      leading: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Container(
          decoration: BoxDecoration(
            color: aero.surface1.withValues(alpha: 0.75),
            shape: BoxShape.circle,
            border: Border.all(color: aero.outline, width: 1.0),
          ),
          child: IconButton(
            icon: const Icon(Symbols.arrow_back_rounded, size: 20),
            color: aero.onSurface,
            tooltip: 'Back',
            onPressed: () {
              if (widget.onClear != null) {
                widget.onClear!();
              } else {
                Navigator.pop(context);
              }
            },
          ),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Container(
            decoration: BoxDecoration(
              color: aero.surface1.withValues(alpha: 0.75),
              shape: BoxShape.circle,
              border: Border.all(color: aero.outline, width: 1.0),
            ),
            child: IconButton(
              icon: const Icon(Symbols.home_rounded, size: 20),
              color: aero.onSurface,
              tooltip: 'Home',
              onPressed: () {
                final nav = context.read<NavigationProvider>();
                if (provider.isLoading) {
                  provider.cancelFetch();
                }
                Navigator.of(context).popUntil((route) => route.isFirst);
                nav.switchToHome();
              },
            ),
          ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail Tile
            ThumbnailTile(
              imageUrl: video.thumbnailUrl,
              borderRadius: BorderRadius.zero,
              fit: BoxFit.cover,
            ),

            // Bottom Gradient Scrim
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.2),
                      Colors.black.withValues(alpha: 0.0),
                      Colors.black.withValues(alpha: 0.85),
                    ],
                    stops: const [0.0, 0.4, 1.0],
                  ),
                ),
              ),
            ),

            // Metadata overlay at bottom of header
            Positioned(
              left: AeroSpace.lg,
              right: AeroSpace.lg,
              bottom: AeroSpace.md,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video.title,
                              style: AeroText.titleSm.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${video.channel} · ${video.formattedViewCount} views',
                              style: AeroText.caption.copyWith(
                                color: Colors.white.withValues(alpha: 0.8),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AeroSpace.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                            width: 1.0,
                          ),
                        ),
                        child: Text(
                          video.formattedDuration,
                          style: AeroText.caption.withTabularFigures().copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // 2. Video Quality Section
  // ==========================================

  Widget _buildVideoQualitySection(
    BuildContext context,
    AeroColors aero,
    VideoProvider provider,
  ) {
    if (provider.availableResolutions.isEmpty) {
      return Text(
        'No resolutions available',
        style: AeroText.bodySm.copyWith(color: aero.onSurfaceMuted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'QUALITY'),
        const SizedBox(height: AeroSpace.sm),

        // Show the full quality ladder without hiding options off-screen.
        Wrap(
          spacing: AeroSpace.sm,
          runSpacing: AeroSpace.sm,
          children: provider.availableResolutions.map((option) {
            final isSelected =
                option.height == provider.selectedResolution?.height;

            return FormatChip(
              label: option.label,
              sizeEstimate: option.formattedSize,
              selected: isSelected,
              onTap: () => provider.selectResolution(option),
            );
          }).toList(),
        ),
        const SizedBox(height: AeroSpace.lg),

        // Codec variants row
        VideoCodecVariantsSection(provider: provider),

        // Audio merge track selector if video is video-only
        if (provider.selectedVideoFormat?.hasAudio == false) ...[
          const SizedBox(height: AeroSpace.lg),
          AudioMergeTrackSelector(provider: provider),
        ],
      ],
    );
  }

  // ==========================================
  // 4. Options Accordion (Collapsible)
  // ==========================================

  Widget _buildOptionsAccordion(
    BuildContext context,
    AeroColors aero,
    VideoProvider provider,
    VideoInfo video,
  ) {
    final settingsProvider = context.watch<PlatformSettingsProvider>();

    return AeroCard(
      borderRadius: AeroRadius.mdBorderRadius,
      backgroundColor: aero.surface1,
      borderColor: aero.outline,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _optionsExpanded = !_optionsExpanded),
            borderRadius: AeroRadius.mdBorderRadius,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AeroSpace.lg,
                vertical: AeroSpace.md,
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.tune_rounded,
                    size: 18,
                    color: aero.onSurfaceMuted,
                  ),
                  const SizedBox(width: AeroSpace.md),
                  Text(
                    'More Options',
                    style: AeroText.bodySm.copyWith(
                      color: aero.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _optionsExpanded ? 0.5 : 0.0,
                    duration: appMotionDuration(context, AppMotion.short),
                    child: Icon(
                      Symbols.keyboard_arrow_down_rounded,
                      size: 20,
                      color: aero.onSurfaceMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Options rows
          if (_optionsExpanded) ...[
            Divider(height: 1, color: aero.outline),

            // Container row
            SettingsRow(
              icon: Symbols.folder_zip_rounded,
              title: 'Container',
              subtitle: provider.audioOnly
                  ? 'Audio stream default'
                  : (provider.selectedVideoFormat?.extension ?? 'mp4')
                        .toUpperCase(),
              trailing: Text(
                provider.audioOnly
                    ? (provider.selectedAudioMergeStream?.extension ?? 'AUDIO')
                          .toUpperCase()
                    : (provider.selectedVideoFormat?.extension ?? 'MP4')
                          .toUpperCase(),
                style: AeroText.caption.copyWith(
                  color: aero.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Divider(height: 1, color: aero.outline),

            // Subtitles row
            SubtitleConfigurationSection(
              provider: provider,
              video: video,
              preferredLanguage: settingsProvider.defaultSubtitleLanguage,
            ),

            // SponsorBlock row
            SettingsRow(
              icon: Symbols.shield_rounded,
              title: 'SponsorBlock',
              subtitle: 'Skip sponsored segments automatically',
              trailing: Switch(
                value: settingsProvider.sponsorBlockEnabled,
                onChanged: (v) => settingsProvider.setSponsorBlockEnabled(v),
                activeThumbColor: aero.primary,
              ),
            ),
            Divider(height: 1, color: aero.outline),

            // Trim row
            SettingsRow(
              icon: Symbols.content_cut_rounded,
              title: 'Trim',
              subtitle: 'Full video (0:00 - ${video.formattedDuration})',
              trailing: Icon(
                Symbols.chevron_right_rounded,
                size: 20,
                color: aero.onSurfaceMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ==========================================
  // 5. Sticky Bottom Action Bar
  // ==========================================

  Widget _buildStickyBottomBar(
    BuildContext context,
    AeroColors aero,
    VideoProvider provider,
    VideoInfo video,
  ) {
    final settingsProvider = context.watch<PlatformSettingsProvider>();
    final outputPath = settingsProvider.settings.outputPath ?? '';

    final estSize = provider.totalEstimatedDownloadSize;
    final String sizeLabel = estSize > 0
        ? ' · ${(estSize / 1024 / 1024).toStringAsFixed(1)} MB'
        : '';

    final videoId = video.id;
    final videoUrl = video.url;

    return Selector<MobileDownloadProvider, (String, DownloadStatus, double)?>(
      selector: (_, p) {
        for (final item in p.activeDownloads) {
          if (item.id == videoId ||
              item.id.startsWith('${videoId}_') ||
              item.url == videoUrl) {
            return (item.id, item.status, item.progress);
          }
        }
        return null;
      },
      builder: (context, snapshot, _) {
        final DownloadStatus? status = snapshot?.$2;
        final bool isPreparing =
            status == DownloadStatus.queued || status == DownloadStatus.pending;
        final bool isDownloading =
            status == DownloadStatus.downloadingVideo ||
            status == DownloadStatus.downloadingAudio ||
            status == DownloadStatus.merging;
        final double progress = snapshot?.$3 ?? 0.0;

        return Container(
          padding: EdgeInsets.fromLTRB(
            AeroSpace.lg,
            AeroSpace.md,
            AeroSpace.lg,
            MediaQuery.paddingOf(context).bottom + AeroSpace.md,
          ),
          decoration: BoxDecoration(
            color: aero.surface1,
            border: Border(top: BorderSide(color: aero.outline, width: 1.0)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Live Progress Line while downloading
              if (isDownloading) ...[
                AeroProgress(value: progress),
                const SizedBox(height: AeroSpace.sm),
              ],

              // Row: Destination Folder Ghost Button
              Row(
                children: [
                  Expanded(
                    child: AeroButton(
                      variant: AeroButtonVariant.ghost,
                      icon: const Icon(Symbols.folder_rounded, size: 16),
                      text: outputPath.isNotEmpty
                          ? outputPath.split(RegExp(r'[\\/]')).last
                          : 'Select Destination Folder',
                      tooltip: outputPath,
                      onPressed: () async {
                        // ignore: deprecated_member_use
                        final picked = await FilePicker.getDirectoryPath();
                        if (picked != null && picked.isNotEmpty) {
                          await settingsProvider.setOutputPath(picked);
                        }
                      },
                    ),
                  ),
                  if (widget.onClear != null && !isDownloading && !isPreparing)
                    AeroButton(
                      variant: AeroButtonVariant.ghost,
                      text: 'Clear',
                      onPressed: widget.onClear,
                    ),
                ],
              ),
              const SizedBox(height: AeroSpace.sm),

              // Full-Width Primary Download Button
              AeroButton(
                variant: AeroButtonVariant.primary,
                expand: true,
                isLoading: isPreparing,
                icon: const Icon(Symbols.download_rounded, size: 18),
                text: isPreparing
                    ? (status == DownloadStatus.queued
                          ? 'Queued...'
                          : 'Preparing...')
                    : isDownloading
                    ? (status == DownloadStatus.merging
                          ? 'Merging · ${(progress * 100).toInt()}%'
                          : 'Downloading · ${(progress * 100).toInt()}%')
                    : 'Download$sizeLabel',
                onPressed: (isDownloading || isPreparing)
                    ? null
                    : () => widget.onDownload(),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================
  // Loading & Error States
  // ==========================================

  Widget _buildLoadingState(
    BuildContext context,
    AeroColors aero,
    VideoProvider provider,
  ) {
    void cancel() {
      final onClear = widget.onClear;
      if (onClear != null) {
        onClear();
      } else {
        provider.cancelFetch();
        Navigator.pop(context);
      }
    }

    return Scaffold(
      backgroundColor: aero.bg,
      appBar: AppBar(
        backgroundColor: aero.surface1,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_rounded),
          tooltip: 'Back',
          onPressed: cancel,
        ),
        title: Text('Download options', style: AeroText.titleSm),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AeroSpace.xxl),
        child: VideoFetchLoading(
          status: provider.loadingStatus,
          video: provider.isPreviewOnly ? provider.videoInfo : null,
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(AeroSpace.lg),
        child: AeroButton(
          variant: AeroButtonVariant.tonal,
          text: 'Cancel',
          onPressed: cancel,
        ),
      ),
    );
  }

  Widget _buildErrorState(
    BuildContext context,
    AeroColors aero,
    VideoProvider provider,
  ) {
    return Scaffold(
      backgroundColor: aero.bg,
      appBar: AppBar(
        backgroundColor: aero.surface1,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_rounded),
          onPressed: () {
            if (widget.onClear != null) {
              widget.onClear!();
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
      body: Center(
        child: EmptyState(
          icon: Symbols.error_rounded,
          title: "Couldn't load video info",
          description: provider.errorMessage ?? 'Failed to load video streams.',
          actionLabel: 'Try again',
          onAction: () {
            final url = provider.currentUrl;
            if (url.isNotEmpty) provider.fetchVideoInfo(url);
          },
          secondaryActionLabel: 'Back',
          onSecondaryAction: () {
            if (widget.onClear != null) {
              widget.onClear!();
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
    );
  }
}
