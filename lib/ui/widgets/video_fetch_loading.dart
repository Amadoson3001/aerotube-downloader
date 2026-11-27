import 'package:flutter/material.dart';

import '../../core/theme/tokens/colors.dart';
import '../../core/theme/tokens/spacing.dart';
import '../../core/theme/tokens/typography.dart';
import '../../models/video_info.dart';
import '../components/aero_progress.dart';
import '../components/thumbnail_tile.dart';

class VideoFetchLoading extends StatelessWidget {
  final String status;
  final VideoInfo? video;

  const VideoFetchLoading({super.key, required this.status, this.video});

  @override
  Widget build(BuildContext context) {
    final colors = context.aero;
    final preview = video;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            status.isEmpty ? 'Checking available download formats…' : status,
            style: AeroText.titleSm.copyWith(color: colors.onSurface),
          ),
        ),
        const SizedBox(height: AeroSpace.md),
        const AeroProgress(semanticsLabel: 'Looking up download options'),
        if (preview != null) ...[
          const SizedBox(height: AeroSpace.xxl),
          ThumbnailTile(
            imageUrl: preview.thumbnailUrl,
            duration: preview.duration > 0 ? preview.formattedDuration : null,
          ),
          const SizedBox(height: AeroSpace.md),
          Text(
            preview.title,
            style: AeroText.titleSm.copyWith(color: colors.onSurface),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (preview.channel.isNotEmpty) ...[
            const SizedBox(height: AeroSpace.xs),
            Text(
              preview.channel,
              style: AeroText.bodySm.copyWith(color: colors.onSurfaceMuted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ],
    );
  }
}
