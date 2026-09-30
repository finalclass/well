// W3 Dart client against the W3 Well server through the generated Proxy. It
// uses only the public toDrut/fromDrut conversions of the generated package.

import 'dart:async';
import 'dart:io';

import '../common.dart';
import '../orders.dart';
import '../proxy_orders.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok) {
  if (ok) {
    pass++;
    print('ok   $name');
  } else {
    fail++;
    print('FAIL $name');
  }
}

Future<ProxyResult<T>> call<T>(
    void Function(void Function(ProxyResult<T>) cb) start) {
  final completer = Completer<ProxyResult<T>>();
  start(completer.complete);
  return completer.future;
}

Future<int> status(String base, String token, String method) async {
  final client = HttpClient();
  try {
    final request =
        await client.postUrl(Uri.parse('$base/rpc/Orders/$method'));
    request.headers.contentType = ContentType.json;
    request.headers.set('X-Requested-With', 'XMLHttpRequest');
    if (token.isNotEmpty) request.headers.set('X-CSRF-Token', token);
    request.write('null');
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } catch (_) {
    return 0;
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final base = args.isNotEmpty ? args[0] : 'http://127.0.0.1:8478';
  final token = args.length > 1 ? args[1] : '';
  final proxy = Proxy(baseUrl: base, csrfToken: token);

  final reservation = await call<ReserveResponse>((cb) => proxy.reserve(
      ReserveRequest(
        ownerId: 'owner-1',
        quantity: 9007199254740991,
        thing: Thing(id: 't-1'),
        tags: ['a', 'b'],
      ),
      cb));
  check(
      'wide reserve',
      reservation.ok &&
          reservation.value is ReserveResponseReserved &&
          (reservation.value as ReserveResponseReserved).value.count ==
              9007199254740991 &&
          (reservation.value as ReserveResponseReserved).value.id == 'owner-1');

  final echo = await call<Thing>(
      (cb) => proxy.echo(Thing(id: 'cross-module'), cb));
  check('cross-module echo', echo.ok && echo.value!.id == 'cross-module');

  final numbers = await call<Numbers>((cb) => proxy.numbers(
      Numbers(
        small: 7,
        big: 9007199254740991,
        negative: -9007199254740991,
        ratio: 1.5,
        unicode: 'Zażółć gęślą jaźń',
      ),
      cb));
  check(
      'wide numbers and unicode',
      numbers.ok &&
          numbers.value!.big == 9007199254740991 &&
          numbers.value!.negative == -9007199254740991 &&
          numbers.value!.unicode == 'Zażółć gęślą jaźń');

  final legacy =
      await call<Thing>((cb) => proxy.echo(Thing(id: 'legacy-error'), cb));
  check('2xx with error body',
      !legacy.ok && (legacy.error ?? '').contains('legacy failure'));

  final bad =
      await call<Thing>((cb) => proxy.echo(Thing(id: 'bad-response'), cb));
  check('invalid response', !bad.ok && (bad.error ?? '').isNotEmpty);

  check('http status 404', await status(base, token, 'unknown_xyz') == 404);

  final offlineProxy =
      Proxy(baseUrl: 'http://127.0.0.1:9', csrfToken: token);
  final offline = await call<Thing>((cb) => offlineProxy.echo(Thing(id: 't'), cb));
  check(
      'network error',
      !offline.ok &&
          (offline.error ?? '').toLowerCase().contains('network'));

  print('\nW3 dart client: $pass passed, $fail failed');
  if (fail > 0) exit(1);
}