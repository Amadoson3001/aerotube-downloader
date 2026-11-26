import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/theme/tokens/colors.dart';
import '../../core/theme/tokens/radius.dart';
import '../../core/theme/tokens/spacing.dart';
import '../../core/theme/tokens/typography.dart';
import '../../models/video_info.dart';
import '../../providers/video_provider.dart';
import '../components/components.dart';

/// Sorts [subtitles] so tracks matching [preferred] language code appear first,
/// breaking ties alphabetically by display name.
List<SubtitleTrack> sortSubtitlesByPreference(
  List<SubtitleTrack> subtitles,
  String preferred,
) {
  if (preferred.isEmpty || preferred == 'auto') return subtitles;
  final prefLower = preferred.toLowerCase();
  final copy = List<SubtitleTrack>.from(subtitles);
  copy.sort((a, b) {
    final aPref = a.languageCode.toLowerCase().startsWith(prefLower);
    final bPref = b.languageCode.toLowerCase().startsWith(prefLower);
    if (aPref == bPref) return a.name.compareTo(b.name);
    return aPref ? -1 : 1;
  });
  return copy;
}

/// Shared codec variant chip selector for the active resolution.
class VideoCodecVariantsSection extends StatelessWidget {
  final VideoProvider provider;
  final String title;
  final EdgeInsetsGeometry? headerMargin;
  final double headerSpacing;
  final bool exactFpsLabel;

  const VideoCodecVariantsSection({
    super.key,
    required this.provider,
    this.title = 'CODEC VARIANTS',
    this.headerMargin,
    this.headerSpacing = AeroSpace.sm,
    this.exactFpsLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    final resolution = provider.selectedResolution;
    if (resolution == null || resolution.formats.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title, margin: headerMargin),
        SizedBox(height: headerSpacing),
        Wrap(
          spacing: AeroSpace.sm,
          runSpacing: AeroSpace.sm,
          children: resolution.formats.map((format) {
            final isSelected =
                provider.selectedVideoFormat?.formatId == format.formatId;
            final container = (format.extension ?? 'mp4').toUpperCase();
            final label = '$container · ${format.codecName}';
            final String? badge;
            if (format.isHdr) {
              badge = 'HDR';
            } else if (format.is60fps) {
              badge = exactFpsLabel
                  ? '${format.fps!.round()}fps'
                  : '60fps';
            } else {
              badge = null;
            }

            return FormatChip(
              label: label,
              badge: badge,
              sizeEstimate: provider.formattedTotalSizeForFormat(format),
              selected: isSelected,
              onTap: () => provider.setSelectedVideoFormat(format),
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// Shared dropdown selector for the audio stream merged with video-only formats.
class AudioMergeTrackSelector extends StatelessWidget {
  final VideoProvider provider;
  final EdgeInsetsGeometry? headerMargin;
  final double headerSpacing;
  final EdgeInsetsGeometry containerPadding;
  final bool showLeadingIcon;

  const AudioMergeTrackSelector({
    super.key,
    required this.provider,
    this.headerMargin,
    this.headerSpacing = AeroSpace.sm,
    this.containerPadding = const EdgeInsets.symmetric(
      horizontal: AeroSpace.md,
    ),
    this.showLeadingIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    final video = provider.videoInfo;
    if (video == null || video.audioOnlyFormats.isEmpty) {
      return const SizedBox.shrink();
    }
    final aero = context.aero;

    final dropdown = DropdownButtonHideUnderline(
      child: DropdownButton<FormatInfo>(
        value: provider.selectedAudioMergeStream,
        isExpanded: true,
        dropdownColor: aero.surface2,
        icon: Icon(
          Symbols.arrow_drop_down_rounded,
          color: aero.onSurfaceMuted,
        ),
        style: AeroText.bodySm.copyWith(color: aero.onSurface),
        onChanged: (newValue) {
          if (newValue != null) {
            provider.setSelectedAudioMergeStream(newValue);
          }
        },
        items: video.audioOnlyFormats.map((format) {
          final bitrate = format.audioBitrate ?? 0;
          final size = format.formattedEstimatedFilesize(video.duration);
          return DropdownMenuItem<FormatInfo>(
            value: format,
            child: Text(
              '${format.audioTrackLabel} · ${bitrate}kbps ($size) [${format.codecName}]',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        }).toList(),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: 'AUDIO TRACK TO MERGE', margin: headerMargin),
        SizedBox(height: headerSpacing),
        Container(
          padding: containerPadding,
          decoration: BoxDecoration(
            color: aero.surface2,
            borderRadius: AeroRadius.smBorderRadius,
            border: Border.all(color: aero.outline, width: 1.0),
          ),
          child: showLeadingIcon
              ? Row(
                  children: [
                    Icon(
                      Symbols.audiotrack_rounded,
                      size: 18,
                      color: aero.primary,
                    ),
                    const SizedBox(width: AeroSpace.md),
                    Expanded(child: dropdown),
                  ],
                )
              : dropdown,
        ),
      ],
    );
  }
}

/// Shared audio quality tier and stream selector.
class AudioQualityConfigurationSection extends StatelessWidget {
  final VideoProvider provider;
  final bool horizontalScrollTiers;
  final double sectionSpacing;
  final double headerSpacing;
  final String emptyStreamsMessage;

  const AudioQualityConfigurationSection({
    super.key,
    required this.provider,
    this.horizontalScrollTiers = false,
    this.sectionSpacing = AeroSpace.lg,
    this.headerSpacing = AeroSpace.sm,
    this.emptyStreamsMessage = 'No audio streams available.',
  });

  @override
  Widget build(BuildContext context) {
    final aero = context.aero;
    final tierChips = AudioQuality.values.map((quality) {
      final isSelected = quality == provider.selectedAudioQuality;
      final chip = FormatChip(
        label: quality.label,
        selected: isSelected,
        onTap: () => provider.setAudioQuality(quality),
      );
      return horizontalScrollTiers
          ? Padding(
              padding: const EdgeInsets.only(right: AeroSpace.sm),
              child: chip,
            )
          : chip;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'AUDIO QUALITY TIER'),
        SizedBox(height: headerSpacing),
        if (horizontalScrollTiers)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: tierChips),
          )
        else
          Wrap(
            spacing: AeroSpace.sm,
            runSpacing: AeroSpace.sm,
            children: tierChips,
          ),
        SizedBox(height: sectionSpacing),
        _buildAudioStreamsList(aero),
      ],
    );
  }

  Widget _buildAudioStreamsList(AeroColors aero) {
    final video = provider.videoInfo;
    if (video == null) return const SizedBox.shrink();

    final audioFormats = video.getAudioFormatsForQuality(
      provider.selectedAudioQuality,
    );
    if (audioFormats.isEmpty) {
      return Text(
        emptyStreamsMessage,
        style: AeroText.bodySm.copyWith(color: aero.onSurfaceMuted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'AUDIO STREAMS'),
        SizedBox(height: headerSpacing),
        Wrap(
          spacing: AeroSpace.sm,
          runSpacing: AeroSpace.sm,
          children: audioFormats.map((format) {
            final isSelected =
                format.formatId == provider.selectedAudioMergeStream?.formatId;
            final ext = (format.extension ?? 'AUDIO').toUpperCase();
            final label = '$ext · ${format.audioBitrate ?? 0}kbps';
            final size = format.formattedEstimatedFilesize(video.duration);

            return FormatChip(
              label: label,
              sizeEstimate: size,
              badge: format.audioTrackLabel,
              selected: isSelected,
              onTap: () => provider.setSelectedAudioMergeStream(format),
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// Shared subtitle embed toggle and sorted language chip selector.
class SubtitleConfigurationSection extends StatelessWidget {
  final VideoProvider provider;
  final VideoInfo video;
  final String preferredLanguage;
  final String selectedCountSuffix;

  const SubtitleConfigurationSection({
    super.key,
    required this.provider,
    required this.video,
    required this.preferredLanguage,
    this.selectedCountSuffix = 'selected',
  });

  @override
  Widget build(BuildContext context) {
    if (video.subtitles.isEmpty) return const SizedBox.shrink();
    final aero = context.aero;
    final sortedSubtitles = sortSubtitlesByPreference(
      video.subtitles,
      preferredLanguage,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsRow(
          icon: Symbols.subtitles_rounded,
          title: 'Subtitles',
          subtitle: provider.selectedSubtitles.isEmpty
              ? 'None selected'
              : '${provider.selectedSubtitles.length} $selectedCountSuffix',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Embed',
                style: AeroText.caption.copyWith(color: aero.onSurfaceMuted),
              ),
              const SizedBox(width: AeroSpace.xs),
              Switch(
                value: provider.embedSubtitles,
                onChanged: provider.selectedSubtitles.isNotEmpty
                    ? (v) => provider.setEmbedSubtitles(v)
                    : null,
                activeThumbColor: aero.primary,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AeroSpace.lg,
            0,
            AeroSpace.lg,
            AeroSpace.md,
          ),
          child: Wrap(
            spacing: AeroSpace.xs,
            runSpacing: AeroSpace.xs,
            children: sortedSubtitles.take(6).map((sub) {
              final isSel = provider.selectedSubtitles.contains(sub);
              return AeroChip(
                text: sub.name,
                selected: isSel,
                onTap: () => provider.toggleSubtitle(sub),
              );
            }).toList(),
          ),
        ),
        Divider(height: 1, color: aero.outline),
      ],
    );
  }
}
