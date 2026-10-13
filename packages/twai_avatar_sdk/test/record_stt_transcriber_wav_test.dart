import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:twai_avatar_sdk/src/record_stt_transcriber_wav.dart';

void main() {
  group('buildWavHeader', () {
    test('emits exactly 44 bytes', () {
      final h = buildWavHeader(
        pcmByteCount: 0,
        sampleRate: 16000,
      );
      expect(h.length, 44);
    });

    test('RIFF/WAVE/fmt /data magic bytes are in the right positions', () {
      final h = buildWavHeader(pcmByteCount: 0, sampleRate: 16000);
      // 'RIFF'
      expect(h.sublist(0, 4), equals([0x52, 0x49, 0x46, 0x46]));
      // 'WAVE'
      expect(h.sublist(8, 12), equals([0x57, 0x41, 0x56, 0x45]));
      // 'fmt '
      expect(h.sublist(12, 16), equals([0x66, 0x6D, 0x74, 0x20]));
      // 'data'
      expect(h.sublist(36, 40), equals([0x64, 0x61, 0x74, 0x61]));
    });

    test('ChunkSize field is 36 + pcmByteCount, little-endian', () {
      // Empty payload → 36.
      final empty = buildWavHeader(pcmByteCount: 0, sampleRate: 16000);
      expect(
        ByteData.sublistView(empty).getUint32(4, Endian.little),
        36,
      );
      // 1024 bytes of PCM → 36 + 1024 = 1060.
      final withPcm = buildWavHeader(pcmByteCount: 1024, sampleRate: 16000);
      expect(
        ByteData.sublistView(withPcm).getUint32(4, Endian.little),
        1060,
      );
    });

    test('AudioFormat = 1 (PCM)', () {
      final h = buildWavHeader(pcmByteCount: 0, sampleRate: 16000);
      expect(ByteData.sublistView(h).getUint16(20, Endian.little), 1);
    });

    test('SampleRate + ByteRate + BlockAlign + BitsPerSample match config', () {
      // 16 kHz mono PCM16: byteRate = 16000 * 1 * 2 = 32000; blockAlign = 2.
      final h16k = buildWavHeader(pcmByteCount: 0, sampleRate: 16000);
      final bd = ByteData.sublistView(h16k);
      expect(bd.getUint16(22, Endian.little), 1); // NumChannels
      expect(bd.getUint32(24, Endian.little), 16000); // SampleRate
      expect(bd.getUint32(28, Endian.little), 32000); // ByteRate
      expect(bd.getUint16(32, Endian.little), 2); // BlockAlign
      expect(bd.getUint16(34, Endian.little), 16); // BitsPerSample

      // 48 kHz stereo PCM16: byteRate = 48000 * 2 * 2 = 192000;
      // blockAlign = 4.
      final h48k = buildWavHeader(
        pcmByteCount: 0,
        sampleRate: 48000,
        numChannels: 2,
      );
      final bd48 = ByteData.sublistView(h48k);
      expect(bd48.getUint16(22, Endian.little), 2);
      expect(bd48.getUint32(24, Endian.little), 48000);
      expect(bd48.getUint32(28, Endian.little), 192000);
      expect(bd48.getUint16(32, Endian.little), 4);
    });

    test('Subchunk2Size = pcmByteCount, little-endian', () {
      final h = buildWavHeader(pcmByteCount: 1024, sampleRate: 16000);
      expect(
        ByteData.sublistView(h).getUint32(40, Endian.little),
        1024,
      );
    });
  });

  group('wrapPcmAsWav', () {
    test('returns header + pcm concatenated, header first', () {
      final pcm = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);
      final wav = wrapPcmAsWav(pcm: pcm, sampleRate: 16000);
      expect(wav.length, 44 + 4);
      // Header magic bytes present at 0.
      expect(wav.sublist(0, 4), equals([0x52, 0x49, 0x46, 0x46]));
      // PCM payload immediately after header.
      expect(wav.sublist(44, 48), equals([0xAA, 0xBB, 0xCC, 0xDD]));
    });

    test('header ChunkSize + Subchunk2Size reflect the wrapped pcm size',
        () {
      final pcm = Uint8List(2048);
      final wav = wrapPcmAsWav(pcm: pcm, sampleRate: 16000);
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(4, Endian.little), 36 + 2048);
      expect(bd.getUint32(40, Endian.little), 2048);
    });

    test('does not mutate the input pcm', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      final copy = Uint8List.fromList(pcm);
      wrapPcmAsWav(pcm: pcm, sampleRate: 16000);
      expect(pcm, equals(copy));
    });
  });
}
