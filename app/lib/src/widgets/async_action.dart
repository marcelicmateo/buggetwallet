import 'package:flutter/widgets.dart';

/// For a State that runs one async action at a time and shows that it is busy (a disabled button, a spinner) and maybe an error line.
///
/// [run] sets [busy], awaits the body and clears [busy] again in a `finally`, but only while the State is still mounted. A body that
/// leaves the screen on success (a pop, a replaced page) does not fit: the button would turn on again before the screen is gone.
mixin AsyncAction<T extends StatefulWidget> on State<T> {
  /// True while a [run] body is running. Buttons disable on it.
  bool busy = false;

  /// The line to show under the buttons, or null. [run] clears it and fills it only when it gets an `onError`.
  String? error;

  /// Runs [body] with [busy] set. Returns its result, or null when it threw and [onError] turned that into [error] (the error is
  /// cleared first). Without [onError] a thrown error goes on to the caller, after [busy] is cleared.
  Future<R?> run<R>(Future<R> Function() body, {String Function(Object e)? onError}) async {
    setState(() {
      busy = true;
      if (onError != null) error = null;
    });
    String? failure;
    try {
      return await body();
    } catch (e) {
      if (onError == null) rethrow;
      failure = onError(e);
      return null;
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          if (failure != null) error = failure;
        });
      }
    }
  }
}
