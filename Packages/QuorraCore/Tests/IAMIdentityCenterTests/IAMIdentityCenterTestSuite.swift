import Testing

/// Parent suite whose `.serialized` trait propagates recursively to the child suites
/// declared via `extension IAMIdentityCenterTestSuite` in sibling files, preventing
/// interleaved access to the global `StubURLProtocol.stubs` dictionary.
@Suite("IAM Identity Center", .serialized)
struct IAMIdentityCenterTestSuite {}
