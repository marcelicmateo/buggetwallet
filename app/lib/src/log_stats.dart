class LogStats {
  final int files, bytes;

  /// Failed writes to the log files since start (disk full, folder not writable…).
  final int writeErrors;
  const LogStats(this.files, this.bytes, [this.writeErrors = 0]);
}
