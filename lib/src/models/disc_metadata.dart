class TrackInfo {
  final int number;
  final String title;
  final String artist;
  final String artistMbid;
  final String recordingMbid;
  final double startTime;
  final double endTime;

  const TrackInfo({
    required this.number,
    required this.title,
    required this.artist,
    required this.artistMbid,
    required this.recordingMbid,
    required this.startTime,
    required this.endTime,
  });

  double get duration => endTime - startTime;

  String get durationLabel {
    final s = duration.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class DiscMetadata {
  final String album;
  final String artist;
  final String artistMbid;
  final String date;
  final String releaseMbid;
  final String label;
  final String catalogNumber;
  final int discNumber;
  final int totalDiscs;
  final List<TrackInfo> tracks;

  const DiscMetadata({
    required this.album,
    required this.artist,
    this.artistMbid = '',
    this.date = '',
    this.releaseMbid = '',
    this.label = '',
    this.catalogNumber = '',
    this.discNumber = 0,
    this.totalDiscs = 1,
    required this.tracks,
  });

  String get albumArtist => artist.isNotEmpty ? artist : 'Various Artists';

  String get artistDir => artist.isNotEmpty ? artist : 'Various Artists';

  String get albumDir =>
      date.isNotEmpty ? '$album ($date)' : album;
}
