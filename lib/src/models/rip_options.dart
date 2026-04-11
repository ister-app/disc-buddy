class RipOptions {
  final String? device;
  final String outputDir;
  final String ffmpeg;
  final String ffprobe;
  final bool force;

  const RipOptions({
    this.device,
    required this.outputDir,
    this.ffmpeg = 'ffmpeg',
    this.ffprobe = 'ffprobe',
    this.force = false,
  });
}
