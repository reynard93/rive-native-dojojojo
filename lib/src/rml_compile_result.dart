import 'dart:typed_data';

/// The outcome of compiling a markup document into `.rev` bytes: exactly one
/// of [bytes] and [error] is set.
///
/// Shared by the ffi and web implementations of `rmlToRev` so callers see one
/// type on both platforms.
class RmlCompileResult {
  /// The compiled `.rev`, or null when the compile failed.
  final Uint8List? bytes;

  /// Why the compile produced nothing: one `<line>: <message>` per error, in
  /// the order the compiler reported them. Null when [bytes] is set.
  final String? error;

  const RmlCompileResult.success(Uint8List this.bytes) : error = null;
  const RmlCompileResult.failure(String this.error) : bytes = null;

  bool get isSuccess => bytes != null;
}
