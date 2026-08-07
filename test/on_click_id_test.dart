// onClickId attribution callback konformans testleri (T14a/b/c).
//
// Spec:
//  S1 yeni bir click_id AKTIF oldugunda tetiklenir (kaynak fark etmez —
//     burada register-click basarisi ile dogrulanir),
//  S2 handler gec set edilirse mevcut degerle HEMEN bir kez cagrilir,
//  S3 ayni deger pes pese tekrar tetiklemez; farkli yeni deger tetikler,
//  S4 teslim asenkron (mikrotask) — set/tetik aninda senkron cagrilmaz,
//  S5 handler opsiyonel; kaldirilinca davranis eskiye doner.

import 'dart:convert';

import 'package:adsparkle_flutter/src/adsparkle.dart';
import 'package:adsparkle_flutter/src/postback_client.dart';
import 'package:adsparkle_flutter/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kClickA = '550e8400-e29b-41d4-a716-446655440000';
const String kClickB = '660e8400-e29b-41d4-a716-446655440111';
const String kRegisteredClick = '770e8400-e29b-41d4-a716-446655440222';

/// Her istege 200 donen sahte HTTP istemcisi; register-click'e sentetik
/// click_id ile basari doner.
MockClient _fakeHttp() => MockClient((http.Request request) async {
      if (request.url.path.endsWith('/api/tracking/register-click')) {
        return http.Response(
          jsonEncode({'success': true, 'click_id': kRegisteredClick}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(jsonEncode({'success': true}), 200,
          headers: {'content-type': 'application/json'});
    });

Future<AdSparkle> _configuredSdk() async {
  final sdk = AdSparkle.forTesting(
    storage: AdSparkleStorage(),
    client: PostbackClient(httpClient: _fakeHttp()),
  );
  await sdk.configure(
    companyKey: 'co_test123',
    baseUrl: 'https://api.example.test',
  );
  return sdk;
}

void main() {
  setUp(() {
    // Temiz depo + platform-kanali gerektiren deferred yollarini atla
    // (Install Referrer / /match testin konusu degil).
    SharedPreferences.setMockInitialValues(<String, Object>{
      'adsparkle.referrer_checked': true,
      'adsparkle.match_checked': true,
    });
  });

  test('T14b: handler gec set edilirse mevcut degerle hemen bir kez cagrilir',
      () async {
    final sdk = await _configuredSdk();
    await sdk.setClickId(kClickA);
    await pumpEventQueue();

    final calls = <String>[];
    sdk.onClickId = calls.add;
    // S4: set aninda SENKRON cagrilmaz — teslim mikrotask'ta.
    expect(calls, isEmpty);
    await pumpEventQueue();
    expect(calls, [kClickA]);

    // Tekrar set edilirse (ayni handler bile olsa) S2 geregi yine hemen cagrilir.
    sdk.onClickId = calls.add;
    await pumpEventQueue();
    expect(calls, [kClickA, kClickA]);
  });

  test('T14c: ayni deger tekrar tetiklemez, farkli yeni deger tetikler',
      () async {
    final sdk = await _configuredSdk();
    final calls = <String>[];
    sdk.onClickId = calls.add;
    await pumpEventQueue();
    expect(calls, isEmpty); // henuz click_id yok → S2 hemen-cagri olmaz

    await sdk.setClickId(kClickA);
    await pumpEventQueue();
    expect(calls, [kClickA]);

    // S3: ayni deger pes pese tekrar tetiklemez.
    await sdk.setClickId(kClickA);
    await pumpEventQueue();
    expect(calls, [kClickA]);

    // S3: FARKLI yeni deger tekrar tetikler.
    await sdk.setClickId(kClickB);
    await pumpEventQueue();
    expect(calls, [kClickA, kClickB]);
  });

  test('T14a: register-click basarisi callbacki dogru degerle tetikler',
      () async {
    final sdk = await _configuredSdk();
    final calls = <String>[];
    sdk.onClickId = calls.add;

    // Link-domain URL'i, click_id'siz → register-click akisi. RegisterClient
    // top-level http.post kullanir; runWithClient ile sahte istemciye yonlenir.
    await http.runWithClient(
      () => sdk.handleDeepLink(
          Uri.parse('https://myapp.go.adsparkle.co/AB12CD?utm_source=x')),
      _fakeHttp,
    );
    await pumpEventQueue();

    expect(calls, [kRegisteredClick]);
    expect(sdk.clickId, kRegisteredClick);
  });

  test('S5: handler kaldirilinca artik cagrilmaz', () async {
    final sdk = await _configuredSdk();
    final calls = <String>[];
    sdk.onClickId = calls.add;
    await sdk.setClickId(kClickA);
    await pumpEventQueue();
    expect(calls, [kClickA]);

    sdk.onClickId = null;
    await sdk.setClickId(kClickB);
    await pumpEventQueue();
    expect(calls, [kClickA]); // yeni teslim yok
  });
}
