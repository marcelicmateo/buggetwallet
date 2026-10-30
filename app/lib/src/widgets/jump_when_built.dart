import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../tabs.dart';

/// For a page's initState, after it added its listener to [request]: runs [jump] after the first frame when a request was made
/// before the page existed (the shell builds hidden pages one by one, so a link can reach a tab whose page is not built yet).
/// [alive] is the State's `mounted`.
void jumpWhenBuilt(JumpRequest<Object?>? request, bool Function() alive, VoidCallback jump) {
  if (request == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (alive() && request.takePending() != null) jump();
  });
}
