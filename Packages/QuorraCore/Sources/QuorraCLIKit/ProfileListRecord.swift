import QuorraIPC

struct ProfileListRecord: Encodable, Equatable {
    let name: String
    let session: String?
    let region: String?
    let account: String
    let role: String

    init(record: QuorraProfileRecord) {
        name = record.name
        session = record.sessionName
        region = record.region
        account = record.accountID
        role = record.roleName
    }
}
