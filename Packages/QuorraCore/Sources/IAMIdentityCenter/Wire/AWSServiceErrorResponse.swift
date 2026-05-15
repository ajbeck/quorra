import Foundation

extension Wire {
    /// AWS service error envelope used by all Portal API endpoints.
    ///
    /// The IAM Identity Center Portal uses AWS REST-JSON 1.1 error format,
    /// which differs from the OIDC endpoints' OAuth `error`/`error_description` shape.
    /// AWS REST-JSON errors use `__type` for the exception class name.
    internal struct AWSServiceErrorResponse: Codable, Sendable {
        /// Exception class name, e.g. `"ForbiddenException"` or `"ResourceNotFoundException"`.
        let type: String
        let message: String?

        enum CodingKeys: String, CodingKey {
            case type = "__type"
            case message
        }
    }
}
