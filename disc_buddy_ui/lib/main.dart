import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/disc_change_watcher_provider.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: DiscBuddyApp()));
}

class DiscBuddyApp extends ConsumerWidget {
  const DiscBuddyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the app-wide disc-swap watcher alive for the whole session.
    ref.watch(discChangeWatcherProvider);
    return MaterialApp(
      title: 'Disc Buddy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
