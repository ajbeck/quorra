# Quorra OpenVPN source and notices

Quorra uses OpenVPN 3 under the Mozilla Public License 2.0. The adjacent source archives contain OpenVPN 3.11.7 and Amazon's seven numbered patches from `openvpn3-3.11.5-aws-1`. Apply the AWS patches in order, followed by the numbered Quorra patches supplied here. AWS's `001-support-saml.patch` does not apply to 3.11.7 without fuzz because upstream added lines beside one hunk, so `001-support-saml-3.11.7.patch` supplied here replaces it; it differs from AWS's copy only in that hunk's context. These files are the corresponding covered source and modifications for this build. The complete MPL text and dependency notices are in the adjacent Licenses folder.

`sources.json` records immutable source revisions, download URLs and SHA-256 values for OpenVPN, AWS modifications, AWS-LC, Asio and LZ4. Build tooling is maintained in `Tooling/Sources/QuorraTooling/ClientVPNCoreReview.swift` and `ClientVPNCorePackage.swift` in the Quorra repository. Run:

```
swift run --package-path Tooling quorra-tooling build vpn-core-review --download --archives DIR --output NEW_REVIEW
swift run --package-path Tooling quorra-tooling build vpn-package --review NEW_REVIEW --output NEW_PACKAGE
```

The main application's AWS SDK and other dependencies have their own notices. This component is not the AWS VPN Client and is not a FIPS-validated product.
