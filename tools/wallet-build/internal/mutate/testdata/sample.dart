// A sample for the mutant finder: comments with ops a + b, true and 1 stay untouched.
import 'dart:math' as math; // 1 + 2
library demo1;
part 'x.dart';
export 'y.dart' show a;

/* block comment: x == y && z,
   return 1; true */
const k = 0;
final big = 007 + 12345678901234567890;

@Deprecated('use b < c')
int add(int a, int b) {
  assert(a > 0 && b > 1);
  if (a < b || a >= 10) return 1;
  final s = 'text with a + b, true, 1 and $a ${a + b}';
  final r = r'raw \ 1 + 2 == 3';
  final t = '''triple
  line a - b ''';
  final u = "double \" quote 1 + 1";
  return a + b * 2 - 1;
}

bool same(String x, String y) {
  if (x == y && x.length != 0) {
    return true;
  }
  return false;
}

double half(double v) => v * 0.5;
double ratio(double a, double b) {
  final p = 1.5 + .5 + a.1 + 2.;
  return a / b;
}

String label(int n) {
  var list = <int>[1, 2, 3];
  List<int> other = [n > 3 ? 1 : 0];
  final x = n >> 1 > 2 && n << 1 < 4;
  final y = n <= 3 && n >= 1 || n ~/ 2 == 1;
  return 'n=$n';
}

int count(List<int> xs) {
  var c = 0x10 + 1e5.toInt();
  for (var i = 0; i < xs.length; i++) {
    c += xs[i];
  }
  return c;
}

class Foo {
  static int get one => 1;
  int get two {
    return 2;
  }
  bool get flag { return !true; }
  String name() {
    return "Čokolada š";
  }
  int _three() {
    return 0;
  }
  Map<String, int> map() {
    return {'a': 1};
  }
}
const žaba = 'ž' + 'č'; // 'ž' == 'č'
var truex = true_value + false1;
