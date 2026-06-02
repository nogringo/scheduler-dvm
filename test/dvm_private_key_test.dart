import 'package:ndk/ndk.dart';
import 'package:scheduler_dvm/scheduler_dvm.dart';
import 'package:test/test.dart';

void main() {
  test('accepts a 64 character hex private key', () {
    const hex =
        '0123456789abcdef0123456789abcdef'
        '0123456789abcdef0123456789abcdef';

    expect(DvmPrivateKey.parse(hex.toUpperCase()).hex, hex);
  });

  test('accepts an nsec private key', () {
    const hex =
        '0123456789abcdef0123456789abcdef'
        '0123456789abcdef0123456789abcdef';
    final nsec = Nip19.encodePrivateKey(hex);

    expect(DvmPrivateKey.parse(nsec).hex, hex);
  });

  test('rejects invalid private keys', () {
    expect(
      () => DvmPrivateKey.parse('npub1not-a-private-key'),
      throwsA(isA<DvmPrivateKeyException>()),
    );
  });
}
