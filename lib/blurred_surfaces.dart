import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'google_letter_palette.dart';

/// Shared blur, safe-area and interactive grab behavior for every AuraLocal
/// sheet. Never attach the dismiss drag to the content: controls, scrolling
/// lists and EQ bands must remain independently draggable.
Future<T?> showAuraSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  Color? backgroundColor,
  bool enableDrag = true,
  bool showDragHandle = false,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close window',
  barrierColor: Colors.black.withValues(alpha: 0.18),
  transitionDuration: const Duration(milliseconds: 260),
  pageBuilder: (page, animation, secondary) => SafeArea(
    top: false,
    child: Align(alignment: Alignment.center,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(page).bottom),
        child: _AuraDraggableSheet(
          builder: builder,
          color: backgroundColor ?? GoogleLetterPalette.cream,
        )))),
  transitionBuilder: (context, animation, secondary, child) => Stack(children: [
    Positioned.fill(child: IgnorePointer(child: AnimatedBuilder(
      animation: animation,
      builder: (_, __) => BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: 7 * animation.value, sigmaY: 7 * animation.value),
        child: const SizedBox.expand())))),
    FadeTransition(opacity: animation, child: SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 0.10), end: Offset.zero)
        .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child)),
  ]),
);

/// Blur is driven by the dialog's actual transition controller, not a timer.
Future<T?> showAuraDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close dialog',
  barrierColor: Colors.black.withValues(alpha: 0.20),
  transitionDuration: const Duration(milliseconds: 250),
  // Center the Material dialog in the already keyboard-resized viewport.
  // Do not apply viewInsets again: the system keyboard would lift the
  // playlist editor twice or jump it while the text field gets focus.
  pageBuilder: (page, animation, secondary) => Center(child: builder(page)),
  transitionBuilder: (context, animation, secondary, child) => Stack(children: [
    Positioned.fill(child: IgnorePointer(child: AnimatedBuilder(
      animation: animation,
      builder: (_, __) => BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 7 * animation.value,
          sigmaY: 7 * animation.value),
        child: const SizedBox.expand())))),
    FadeTransition(opacity: animation, child: ScaleTransition(
      scale: Tween<double>(begin: 0.96, end: 1).animate(
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child)),
  ]),
);

class _AuraDraggableSheet extends StatefulWidget {
  final WidgetBuilder builder;
  final Color color;
  const _AuraDraggableSheet({required this.builder, required this.color});
  @override
  State<_AuraDraggableSheet> createState() => _AuraDraggableSheetState();
}

class _AuraDraggableSheetState extends State<_AuraDraggableSheet> {
  double distance = 0;
  bool dragging = false;
  void finish(DragEndDetails details) {
    if (distance > 110 || (details.primaryVelocity ?? 0) > 650) {
      Navigator.of(context).pop();
    } else {
      setState(() { dragging = false; distance = 0; });
    }
  }
  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return AnimatedContainer(
      duration: dragging ? Duration.zero : const Duration(milliseconds: 210),
      curve: Curves.easeOutCubic,
      transform: Matrix4.translationValues(0, distance, 0),
      child: Material(color: Colors.transparent,
        child: Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
          child: ClipRRect(borderRadius: BorderRadius.circular(26),
            child: ConstrainedBox(constraints: BoxConstraints(
                maxHeight: height * 0.94),
              // ListTile ink and highlights require an actual Material surface
              // at the sheet background, not a ColoredBox in front of it.
              child: Material(color: widget.color,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  GestureDetector(key: const Key('aura-sheet-grab-zone'),
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: (_) => setState(() => dragging = true),
                    onVerticalDragUpdate: (details) => setState(() =>
                      distance = (distance + details.delta.dy).clamp(0.0, height).toDouble()),
                    onVerticalDragEnd: finish,
                    onVerticalDragCancel: () => setState(() {
                      dragging = false; distance = 0;
                    }),
                    child: SizedBox(height: 46, width: double.infinity,
                      child: Center(child: Container(width: 65, height: 6,
                        decoration: BoxDecoration(
                          color: GoogleLetterPalette.creamDivider,
                          borderRadius: BorderRadius.circular(6)))))),
                  Flexible(fit: FlexFit.loose, child: widget.builder(context)),
                ])))))),
    );
  }
}
