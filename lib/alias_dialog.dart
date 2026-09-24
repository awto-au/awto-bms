/// #44: the rename dialog for a pack's local custom name, shared by the list
/// rows, the detail page and the desktop pane (#68).
library;

import 'package:flutter/material.dart';

import 'alias_store.dart';

/// Rename dialog for a pack's local custom name. Pre-fills the current alias;
/// Save writes through the shared [AliasStore] (an empty field clears the
/// alias back to the bare serial). Purely local — nothing sent to the BMS.
Future<AliasEditOutcome> editBatteryAlias(
    BuildContext context, AliasStore aliases, String serial) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(
        serial: serial, initial: aliases.aliasFor(serial) ?? ''),
  );
  if (result == null) return AliasEditOutcome.dismissed;
  return aliases.setAlias(serial, result);
}

/// #57 (the red `'_dependents.isEmpty': is not true` screen): the dialog OWNS
/// its [TextEditingController] and disposes it in [State.dispose] — i.e. only
/// once the dialog route has fully left the tree. The previous code disposed
/// the controller right after `await showDialog(...)`, which resolves when the
/// dialog is POPPED, while its TextField stays mounted for the pop transition.
/// The route's own status change rebuilds that TextField, whose
/// `didUpdateWidget` re-listens on the now-disposed controller and throws
/// inside `Element.update`; that leaves part of the dialog subtree orphaned
/// with live inherited dependencies, and the route's teardown then fails the
/// framework's `_dependents.isEmpty` assertion — bringing the whole app down
/// to the red screen. Regression test: test/crash_57_test.dart.
class _RenameDialog extends StatefulWidget {
  final String serial;
  final String initial;
  const _RenameDialog({required this.serial, required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename battery'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.serial,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Custom name',
              hintText: 'e.g. Left battery',
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          const SizedBox(height: 4),
          const Text('Leave empty to clear back to the serial.',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
