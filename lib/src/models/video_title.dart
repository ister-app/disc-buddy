/// Common interface for a single rippable video title on a disc.
///
/// Implemented by [DvdTitle] and [BlurayTitle]. Allows disc-type-agnostic code
/// (title display, selection, naming) to work uniformly for both formats.
abstract interface class VideoTitle {
  /// Key shown to the user and used in title-selection maps ("3", "3.2", …).
  String get displayKey;

  Duration get duration;

  /// "HH:MM:SS" formatted duration label.
  String get durationLabel;

  /// Output MKV filename, e.g. "title_07.mkv".
  String get filename;

  int get audioStreamCount;
  int get subtitleStreamCount;
  bool get hasSubtitles;

  /// Chapter start timestamps relative to title start.
  List<Duration> get chapters;

  /// Optional suffix appended to the title-list line, e.g. "  (angle 2/3)"
  /// or "  [00001]". Null → no suffix.
  String? get extraInfo;

  /// True for single-angle titles and primary angles (pgcIndex == 0 on DVD,
  /// always true on Blu-ray). Used by the generic fallback selection when no
  /// suggestion is present and the user presses Enter.
  bool get isPrimary;

  /// Returns true if this title is a reasonable match for a user-typed [key]
  /// that was not found in the primary title map. Override to support
  /// disc-specific shorthand (e.g. "3" matching VTS 3 on DVD).
  bool matchesKey(String key) => false;
}
