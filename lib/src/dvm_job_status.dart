enum DvmJobStatus { scheduled, published, failed, cancelled }

extension DvmJobStatusX on DvmJobStatus {
  bool get isTerminal {
    return switch (this) {
      DvmJobStatus.published ||
      DvmJobStatus.failed ||
      DvmJobStatus.cancelled => true,
      DvmJobStatus.scheduled => false,
    };
  }
}
