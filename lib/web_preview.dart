import 'package:flutter/material.dart';

void main() => runApp(const AuraPreview());

class AuraPreview extends StatelessWidget {
  const AuraPreview({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AuraLocal Browser Preview',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xFF101218),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF56E5AC), brightness: Brightness.dark),
    ),
    home: const PreviewHome(),
  );
}

class PreviewHome extends StatefulWidget {
  const PreviewHome({super.key});
  @override
  State<PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<PreviewHome> {
  final tracks = <String>['Super Mario World - Overworld', 'Shining Force II - Battle', 'Ancient Ruins - Theme', 'Circuit Breaker'];
  String search = '';
  int current = 0;
  bool playing = false;
  bool nowPlaying = false;
  bool shuffle = false;
  int repeat = 0;
  double position = 0.25;

  @override
  Widget build(BuildContext context) {
    final filtered = tracks.asMap().entries.where((e) => e.value.toLowerCase().contains(search.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(nowPlaying ? 'Now Playing' : 'Your Library'),
        leading: nowPlaying ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => nowPlaying = false)) : null,
        actions: [if (!nowPlaying) IconButton(
          tooltip: 'Add demo song',
          onPressed: () => setState(() => tracks.add('Demo Track ${tracks.length + 1}')),
          icon: const Icon(Icons.add_circle_outline),
        )],
      ),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 700), child: nowPlaying ? _player() : Column(children: [
        const Padding(padding: EdgeInsets.all(12), child: Text('BROWSER UI PREVIEW — sample tracks, no iOS audio engine', style: TextStyle(color: Colors.amberAccent, fontSize: 11))),
        Padding(padding: const EdgeInsets.all(16), child: TextField(
          onChanged: (s) => setState(() => search = s),
          decoration: InputDecoration(hintText: 'Search songs', prefixIcon: const Icon(Icons.search), filled: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
        )),
        Expanded(child: ListView.builder(
          itemCount: filtered.length,
          itemBuilder: (_, i) {
            final item = filtered[i];
            return ListTile(
              leading: const CircleAvatar(child: Icon(Icons.music_note)),
              title: Text(item.value),
              subtitle: const Text('Demo artist'),
              onTap: () => setState(() { current = item.key; playing = true; nowPlaying = true; }),
            );
          },
        )),
        if (tracks.isNotEmpty) ListTile(
          tileColor: const Color(0xFF25453B),
          title: Text(tracks[current], maxLines: 1, overflow: TextOverflow.ellipsis),
          leading: const Icon(Icons.graphic_eq),
          onTap: () => setState(() => nowPlaying = true),
          trailing: IconButton(icon: Icon(playing ? Icons.pause : Icons.play_arrow), onPressed: () => setState(() => playing = !playing)),
        ),
      ]))),
    );
  }

  Widget _player() => Padding(padding: const EdgeInsets.all(24), child: Column(children: [
    const Spacer(),
    Expanded(flex: 5, child: Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), gradient: const LinearGradient(colors: [Color(0xFF295548), Color(0xFF181B2B)])),
      child: const Center(child: Icon(Icons.music_note, size: 120, color: Color(0xFF9BE9C6))))),
    const SizedBox(height: 24),
    Text(tracks[current], textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    const Text('Demo artist', style: TextStyle(color: Colors.white60)),
    const SizedBox(height: 24),
    Slider(value: position, onChanged: (v) => setState(() => position = v)),
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text('${(position * 180 ~/ 60)}:${((position * 180).toInt() % 60).toString().padLeft(2, '0')}'),
      const Text('3:00'),
    ]),
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      IconButton(onPressed: () => setState(() => shuffle = !shuffle), color: shuffle ? Colors.tealAccent : Colors.white, icon: const Icon(Icons.shuffle)),
      IconButton(onPressed: () => setState(() { current = (current - 1 + tracks.length) % tracks.length; position = 0; }), icon: const Icon(Icons.skip_previous), iconSize: 36),
      IconButton.filled(onPressed: () => setState(() => playing = !playing), icon: Icon(playing ? Icons.pause : Icons.play_arrow), iconSize: 36),
      IconButton(onPressed: () => setState(() { current = (current + 1) % tracks.length; position = 0; }), icon: const Icon(Icons.skip_next), iconSize: 36),
      IconButton(onPressed: () => setState(() => repeat = (repeat + 1) % 3), color: repeat == 0 ? Colors.white : Colors.tealAccent, icon: Icon(repeat == 2 ? Icons.repeat_one : Icons.repeat)),
    ]),
    const SizedBox(height: 12),
    const Text('Visual preview only — controls do not play audio', style: TextStyle(fontSize: 12, color: Colors.white54)),
    const Spacer(),
  ]));
}
