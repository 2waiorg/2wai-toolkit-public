import 'dart:typed_data';

/// 44-byte RIFF/WAVE PCM header builder — used by [RecordSttTranscriber]
/// to wrap raw PCM captured via the `record` package before POSTing to
/// a Whisper-shaped STT endpoint.
///
/// A WAV header lets the server decode without knowing sample rate /
/// channel count / bit depth a priori. Gen-2wai's dictation endpoint,
/// OpenAI Whisper, ElevenLabs Scribe, Deepgram batch — all accept WAV
/// directly. Raw PCM would require server-side out-of-band configuration
/// for each customer STT endpoint, so the extra 44 bytes buys wide
/// portability at negligible bandwidth cost (0.28% of a 1-second 16 kHz
/// mono clip; less at higher sample rates).
///
/// Format details, spec-order:
///
///     Offset  Size  Field           Value for PCM 16-bit
///     ------  ----  -----           --------------------
///     0       4     RIFF magic      'RIFF'
///     4       4     ChunkSize       36 + Subchunk2Size
///     8       4     Format          'WAVE'
///     12      4     Subchunk1 magic 'fmt '
///     16      4     Subchunk1Size   16 (PCM)
///     20      2     AudioFormat     1  (PCM)
///     22      2     NumChannels     numChannels
///     24      4     SampleRate      sampleRate
///     28      4     ByteRate        sampleRate * numChannels * 2
///     32      2     BlockAlign      numChannels * 2
///     34      2     BitsPerSample   16
///     36      4     Subchunk2 magic 'data'
///     40      4     Subchunk2Size   pcmByteCount
///
/// Reference: http://soundfile.sapp.org/doc/WaveFormat/
Uint8List buildWavHeader({
  required int pcmByteCount,
  required int sampleRate,
  int numChannels = 1,
  int bitsPerSample = 16,
}) {
  final header = Uint8List(44);
  final byteData = ByteData.sublistView(header);

  // Little-endian for every multi-byte field; ASCII magic is written
  // byte-by-byte because Dart's ByteData doesn't have a "set 4 chars"
  // primitive.
  //
  // 'RIFF'
  header[0] = 0x52;
  header[1] = 0x49;
  header[2] = 0x46;
  header[3] = 0x46;
  // ChunkSize = fileSize - 8 = (36 + pcmByteCount)
  byteData.setUint32(4, 36 + pcmByteCount, Endian.little);
  // 'WAVE'
  header[8] = 0x57;
  header[9] = 0x41;
  header[10] = 0x56;
  header[11] = 0x45;
  // 'fmt '
  header[12] = 0x66;
  header[13] = 0x6D;
  header[14] = 0x74;
  header[15] = 0x20;
  // Subchunk1Size = 16 for PCM
  byteData.setUint32(16, 16, Endian.little);
  // AudioFormat = 1 (PCM)
  byteData.setUint16(20, 1, Endian.little);
  // NumChannels
  byteData.setUint16(22, numChannels, Endian.little);
  // SampleRate
  byteData.setUint32(24, sampleRate, Endian.little);
  // ByteRate = SampleRate * NumChannels * BitsPerSample/8
  final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
  byteData.setUint32(28, byteRate, Endian.little);
  // BlockAlign = NumChannels * BitsPerSample/8
  byteData.setUint16(32, numChannels * (bitsPerSample ~/ 8), Endian.little);
  // BitsPerSample
  byteData.setUint16(34, bitsPerSample, Endian.little);
  // 'data'
  header[36] = 0x64;
  header[37] = 0x61;
  header[38] = 0x74;
  header[39] = 0x61;
  // Subchunk2Size = pcmByteCount
  byteData.setUint32(40, pcmByteCount, Endian.little);

  return header;
}

/// Prepends a WAV header to a chunk of raw PCM samples.
///
/// Returns a fresh [Uint8List] with header + pcm concatenated. Doesn't
/// mutate the input.
Uint8List wrapPcmAsWav({
  required Uint8List pcm,
  required int sampleRate,
  int numChannels = 1,
  int bitsPerSample = 16,
}) {
  final header = buildWavHeader(
    pcmByteCount: pcm.length,
    sampleRate: sampleRate,
    numChannels: numChannels,
    bitsPerSample: bitsPerSample,
  );
  final out = Uint8List(header.length + pcm.length);
  out.setRange(0, header.length, header);
  out.setRange(header.length, out.length, pcm);
  return out;
}
