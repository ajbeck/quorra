// ManagedHeader.swift — prepend-on-first-managed-write logic.
//
// Decision D04: first managed write prepends a header comment noting Quorra ownership.
// Plan §14.2 task 4.
//
// The header lives in Document.leadingComments and round-trips through write→read.
// It is content data, not metadata — it appears in the file as a plain comment line.

/// Ensures the managed-mode header comment is the first entry in `document.leadingComments`.
///
/// Idempotent: if the header is already the first leading comment, this is a no-op.
/// If the document has other leading comments but the header is absent or not first,
/// the header is prepended ahead of the existing comments.
///
/// - Parameters:
///   - document: The document to mutate in place.
///   - options: Options carrying `managedHeaderText` (the exact header string).
func ensureManagedHeader(in document: inout AWSConfigINIDocument, options: AWSConfigINIDocumentOptions) {
    let header = options.managedHeaderText
    if document.leadingComments.first == header {
        // Already present as the first leading comment — nothing to do.
        return
    }
    // Prepend ahead of any existing leading comments.
    document.leadingComments.insert(header, at: 0)
}
