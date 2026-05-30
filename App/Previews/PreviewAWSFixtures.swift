#if DEBUG
enum PreviewAWSFixtures {
    static let mockupConfig = """
    [sso-session astrocompute]
    sso_start_url = https://astrocompute.awsapps.com/start
    sso_region = us-east-2
    sso_registration_scopes = sso:account:access

    [sso-session orion-labs]
    sso_start_url = https://orion-labs.awsapps.com/start
    sso_region = us-west-2
    sso_registration_scopes = sso:account:access

    [profile ac:cp:org_admin]
    sso_session = astrocompute
    sso_account_id = 699475923216
    sso_role_name = OrganizationAdmin
    region = us-east-2
    output = json

    [profile ac:mgmt:admin]
    sso_session = astrocompute
    sso_account_id = 699475923216
    sso_role_name = ManagementAdmin
    region = us-east-2
    output = json

    [profile ac:mgmt:org_admin]
    sso_session = astrocompute
    sso_account_id = 699475923216
    sso_role_name = ManagementOrganizationAdmin
    region = us-east-2
    output = json

    [profile ac:personal:org_admin]
    sso_session = astrocompute
    sso_account_id = 699475923216
    sso_role_name = PersonalOrganizationAdmin
    region = us-east-2
    output = json

    [profile ac:spaceport:org_admin]
    sso_session = astrocompute
    sso_account_id = 699475923216
    sso_role_name = SpaceportOrganizationAdmin
    region = us-east-2
    output = json

    [profile orion:dev:read]
    sso_session = orion-labs
    sso_account_id = 824177590102
    sso_role_name = ReadOnlyAccess
    region = us-west-2
    output = json

    [profile orion:prod:read]
    sso_session = orion-labs
    sso_account_id = 824177590102
    sso_role_name = ReadOnlyAccess
    region = us-west-2
    output = json
    """

    static let mockupCredentials = """
    [deploy:legacy]
    aws_access_key_id = test-default-access-key
    aws_secret_access_key = WJALRXUTNFEMIEXAMPLE

    [personal:archive]
    aws_access_key_id = AKIAJK4OOIK4OOIK4OOI
    aws_secret_access_key = SECRETDO NOT USE
    """
}
#endif
