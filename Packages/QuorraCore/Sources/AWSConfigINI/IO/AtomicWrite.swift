// AtomicWrite.swift — atomic write-tmp-then-rename helper.
//
// M05: Plan §11.2 task 2.
//
// Design decision (lighter path per mission brief):
//
//   `writeAtomically(data:to:)` wraps `Data.write(to: options: .atomic)`.
//   Foundation implements `.atomic` by writing to a sibling temp file and
//   then calling rename(2) over the destination — exactly what plan §11.2
//   task 2 describes. We do not re-implement the rename loop manually;
//   instead, this is a typed-error wrapper that converts Foundation's untyped
//   `throws` to `AWSConfigINIError.ioError`.
//
//   Note on fsync: `Data.write(to: options: .atomic)` does NOT guarantee an
//   explicit fsync before rename. For the Quorra use case (AWS config files on
//   the local APFS volume, not NFS/network shares), this is acceptable — the
//   kernel page cache ensures the data is committed on the local volume.
//   If a hard fsync guarantee is required in future, replace with a manual
//   open/write/fsync/close/rename sequence. Document this in the caller.

import Foundation

/// Writes `data` atomically to `url`.
///
/// Uses `Data.write(to:options:.atomic)` which internally writes to a sibling
/// temp file and renames it over the destination — equivalent to the
/// write-tmp+rename(2) pattern described in plan §11.2 task 2.
///
/// - Throws: `AWSConfigINIError.ioError(url, underlying:)` on any write failure.
func writeAtomically(data: Data, to url: URL) throws(AWSConfigINIError) {
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        throw .ioError(url, underlying: error)
    }
}
