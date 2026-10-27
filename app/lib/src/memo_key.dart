import 'package:flutter/foundation.dart' show immutable;

/// The key of one cached derived value in `WalletController.memo`: a [name] and the [args] it was computed for (a value or a
/// record of values; records, strings, numbers and enums compare by value). The arguments never merge into the name, so two
/// different calls can not end up with the same key, whatever text the arguments hold.
@immutable
class MemoKey {
  const MemoKey(this.name, [this.args]);

  final String name;
  final Object? args;

  @override
  bool operator ==(Object other) => other is MemoKey && other.name == name && other.args == args;

  @override
  int get hashCode => Object.hash(name, args);

  @override
  String toString() => 'MemoKey($name, $args)';
}
