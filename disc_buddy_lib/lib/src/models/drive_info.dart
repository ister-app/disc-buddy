enum DiscStatus { ejected, loading, noDisc, audioCD, dataDisc, unknown }

class DriveInfo {
  final String device;
  final String vendor;
  final String model;
  final DiscStatus status;
  final int audioCDTracks;
  final String label;

  const DriveInfo({
    required this.device,
    required this.vendor,
    required this.model,
    required this.status,
    this.audioCDTracks = 0,
    this.label = '',
  });

  String get displayModel => '$vendor $model'.trim();

  String get statusLabel => switch (status) {
    DiscStatus.ejected  => '(open / ejected)',
    DiscStatus.loading  => '(loading...)',
    DiscStatus.noDisc   => '(no disc)',
    DiscStatus.audioCD  => 'Audio CD ($audioCDTracks tracks)',
    DiscStatus.dataDisc => label.isNotEmpty ? label : '(disc present)',
    DiscStatus.unknown  => '(disc present)',
  };
}
