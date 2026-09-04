import 'dart:async';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/storage_service.dart';

/// Drop-in replacement for a plain squad-name TextField. Suggests existing
/// players from the global registry as the user types, and reports back
/// which existing player (if any) was picked so the caller can reuse its
/// id instead of minting a new duplicate one.
///
/// Usage (e.g. inside the squad editor in start_match_screen.dart):
///
///   PlayerAutocompleteField(
///     controller: nameController,
///     onExistingSelected: (p) => squadGlobalIds[index] = p.id,
///   )
///
/// If the user types a brand-new name instead of picking a suggestion,
/// call `StorageService.findOrCreateGlobalPlayer(name)` when the squad is
/// actually saved (not on every keystroke) to register it.
class PlayerAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final String? labelText;
  final ValueChanged<GlobalPlayer>? onExistingSelected;

  const PlayerAutocompleteField({
    super.key,
    required this.controller,
    this.labelText = 'Player name',
    this.onExistingSelected,
  });

  @override
  State<PlayerAutocompleteField> createState() => _PlayerAutocompleteFieldState();
}

class _PlayerAutocompleteFieldState extends State<PlayerAutocompleteField> {
  Timer? _debounce;

  Future<List<GlobalPlayer>> _search(String query) async {
    // Simple debounce so every keystroke doesn't fire a network request.
    final completer = Completer<List<GlobalPlayer>>();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final results = await StorageService.searchGlobalPlayers(query);
      if (!completer.isCompleted) completer.complete(results);
    });
    return completer.future;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Autocomplete<GlobalPlayer>(
      initialValue: TextEditingValue(text: widget.controller.text),
      displayStringForOption: (p) => p.name,
      optionsBuilder: (value) => _search(value.text),
      onSelected: (p) {
        widget.controller.text = p.name;
        widget.onExistingSelected?.call(p);
      },
      fieldViewBuilder: (context, fieldController, focusNode, onFieldSubmitted) {
        // Keep the two controllers in sync so the caller's controller
        // (used elsewhere, e.g. when building the squad list) stays current.
        fieldController.text = widget.controller.text;
        fieldController.addListener(() {
          widget.controller.text = fieldController.text;
        });
        return TextField(
          controller: fieldController,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: widget.labelText,
            prefixIcon: const Icon(Icons.person_search),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_outline),
                    title: Text(option.name),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
