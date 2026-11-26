import '../models/download_item.dart';

final DateTime _historyEpoch = DateTime.fromMillisecondsSinceEpoch(0);

/// Returns true when [status] represents an actively transferring or merging job.
bool isRunningDownloadStatus(DownloadStatus status) =>
    status == DownloadStatus.downloadingVideo ||
    status == DownloadStatus.downloadingAudio ||
    status == DownloadStatus.merging;

/// Returns true when [status] is waiting in the queue before transfer starts.
bool isQueuedDownloadStatus(DownloadStatus status) =>
    status == DownloadStatus.pending || status == DownloadStatus.queued;

/// Returns true when [status] is non-terminal (running, queued, or paused).
bool isActiveDownloadStatus(DownloadStatus status) =>
    isRunningDownloadStatus(status) ||
    isQueuedDownloadStatus(status) ||
    status == DownloadStatus.paused;

/// Returns true when [status] is terminal (completed, failed, or cancelled).
bool isTerminalDownloadStatus(DownloadStatus status) =>
    status == DownloadStatus.completed ||
    status == DownloadStatus.failed ||
    status == DownloadStatus.cancelled;

/// Orders history entries newest-first by [DownloadItem.completedDate].
int compareHistoryNewestFirst(DownloadItem a, DownloadItem b) =>
    (b.completedDate ?? _historyEpoch).compareTo(
      a.completedDate ?? _historyEpoch,
    );

/// Orders history entries oldest-first by [DownloadItem.completedDate].
int compareHistoryOldestFirst(DownloadItem a, DownloadItem b) =>
    (a.completedDate ?? _historyEpoch).compareTo(
      b.completedDate ?? _historyEpoch,
    );

/// Normalizes a raw progress value to the inclusive `[0.0, 1.0]` range.
double clampDownloadProgress(double progress) =>
    progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0).toDouble();
