enum DiscStatus {
  ejected,
  loading,
  noDisc,
  audioCD,
  dataDisc,

  /// The drive no longer answers at the transport layer (dead SATA/USB link,
  /// port disabled by the kernel).  Looks like an open tray to
  /// `CDROM_DRIVE_STATUS`, so it is detected separately — see [driveResponds].
  unreachable,
  unknown,
}

class DriveInfo {
  final String device;
  final String vendor;
  final String model;
  final DiscStatus status;
  final int audioCDTracks;
  final String label;

  /// Cheap udev-derived identity of the inserted medium ('' when none).
  /// Changes when the disc is swapped — used to invalidate stale scans.
  final String mediaId;

  const DriveInfo({
    required this.device,
    required this.vendor,
    required this.model,
    required this.status,
    this.audioCDTracks = 0,
    this.label = '',
    this.mediaId = '',
  });

  String get displayModel => '$vendor $model'.trim();

  String get statusLabel => switch (status) {
    DiscStatus.ejected  => '(open / ejected)',
    DiscStatus.loading  => '(loading...)',
    DiscStatus.noDisc   => '(no disc)',
    DiscStatus.unreachable => '(not responding — check power/cable)',
    DiscStatus.audioCD  => 'Audio CD ($audioCDTracks tracks)',
    DiscStatus.dataDisc => label.isNotEmpty ? label : '(disc present)',
    DiscStatus.unknown  => '(disc present)',
  };
}
