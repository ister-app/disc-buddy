import 'dart:io';

/// Returns the mount point of [device], or null if not mounted.
Future<String?> findMountPoint(String device) async {
  final r = await Process.run('findmnt', ['-n', '-o', 'TARGET', device]);
  if (r.exitCode != 0) return null;
  final path = (r.stdout as String).trim();
  return path.isEmpty ? null : path;
}

/// Runs [action] with the mount point of [device].
///
/// If [device] is a plain file (ISO image), it is loop-mounted via udisksctl
/// and the loop device is torn down afterwards.
/// If [device] is a block device, it is mounted via udisksctl if not already
/// mounted, and unmounted afterwards.
/// Returns null on mount failure.
/// [errorContext] is included in the error message, e.g. "DVD" or "Blu-ray".
Future<T?> withMountedDisc<T>(
  String device,
  Future<T?> Function(String mountPath) action, {
  String errorContext = '',
}) async {
  if (await FileSystemEntity.type(device) == FileSystemEntityType.file) {
    return _withMountedIso(device, action, errorContext: errorContext);
  }

  String? mountPath = await findMountPoint(device);
  final weDidMount = mountPath == null;

  if (weDidMount) {
    final mount = await Process.run(
      'udisksctl', ['mount', '--block-device', device, '--no-user-interaction'],
    );
    if (mount.exitCode != 0) {
      final ctx = errorContext.isNotEmpty ? '$errorContext-' : '';
      stderr.writeln('Error: ${ctx}mount failed '
          '(${(mount.stderr as String).trim()})');
      return null;
    }
    final out   = (mount.stdout as String).trim();
    final atIdx = out.lastIndexOf(' at ');
    if (atIdx < 0) {
      stderr.writeln('Error: mount point not found in: $out');
      return null;
    }
    mountPath = out.substring(atIdx + 4).replaceAll(RegExp(r'\.$'), '');
  }

  try {
    return await action(mountPath);
  } finally {
    if (weDidMount) {
      await Process.run(
        'udisksctl', ['unmount', '--block-device', device, '--no-user-interaction'],
      );
    }
  }
}

/// Mounts an ISO image as a loop device via udisksctl and runs [action] with
/// the resulting mount point. The loop device is unmounted and deleted
/// afterwards regardless of whether [action] succeeds or throws.
Future<T?> _withMountedIso<T>(
  String isoPath,
  Future<T?> Function(String mountPath) action, {
  String errorContext = '',
}) async {
  final ctx = errorContext.isNotEmpty ? '$errorContext-' : '';

  // Create a loop device for the ISO file.
  final setup = await Process.run(
    'udisksctl', ['loop-setup', '--file', isoPath, '--no-user-interaction'],
  );
  if (setup.exitCode != 0) {
    stderr.writeln('Error: ${ctx}ISO loop-setup failed '
        '(${(setup.stderr as String).trim()})');
    return null;
  }
  // Output: "Mapped file /path/to/file.iso as /dev/loop0."
  final setupOut    = (setup.stdout as String).trim();
  final loopMatch   = RegExp(r'(/dev/loop\d+)').firstMatch(setupOut);
  final loopDevice  = loopMatch?.group(1);
  if (loopDevice == null) {
    stderr.writeln('Error: could not parse loop device from: $setupOut');
    return null;
  }

  // Mount the loop device (it may already be mounted from a previous run).
  String mountPath;
  final existingMount = await findMountPoint(loopDevice);
  if (existingMount != null) {
    mountPath = existingMount;
  } else {
    final mount = await Process.run(
      'udisksctl', ['mount', '--block-device', loopDevice, '--no-user-interaction'],
    );
    if (mount.exitCode != 0) {
      // GNOME/udisks may have auto-mounted the loop device between the
      // findMountPoint check and our mount call. Extract the path from the
      // "already mounted at '/path'" error rather than treating it as fatal.
      final errStr = (mount.stderr as String).trim();
      final alreadyAt = RegExp(r"already mounted at `([^']+)'").firstMatch(errStr)
          ?? RegExp(r'already mounted at "([^"]+)"').firstMatch(errStr);
      if (alreadyAt != null) {
        mountPath = alreadyAt.group(1)!;
      } else {
        await Process.run(
          'udisksctl', ['loop-delete', '--block-device', loopDevice, '--no-user-interaction'],
        );
        stderr.writeln('Error: ${ctx}ISO mount failed ($errStr)');
        return null;
      }
    } else {
      final mountOut = (mount.stdout as String).trim();
      final atIdx    = mountOut.lastIndexOf(' at ');
      if (atIdx < 0) {
        await Process.run('udisksctl', ['unmount', '--block-device', loopDevice, '--no-user-interaction']);
        await Process.run('udisksctl', ['loop-delete', '--block-device', loopDevice, '--no-user-interaction']);
        stderr.writeln('Error: mount point not found in: $mountOut');
        return null;
      }
      mountPath = mountOut.substring(atIdx + 4).replaceAll(RegExp(r'\.$'), '');
    }
  }

  try {
    return await action(mountPath);
  } finally {
    await Process.run('udisksctl', ['unmount',     '--block-device', loopDevice, '--no-user-interaction']);
    await Process.run('udisksctl', ['loop-delete', '--block-device', loopDevice, '--no-user-interaction']);
  }
}
