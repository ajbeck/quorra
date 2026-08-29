# Changelog

## [0.1.2](https://github.com/ajbeck/quorra/compare/v0.1.1...v0.1.2) (2026-08-29)


### Bug Fixes

* **release:** rely on stapler validation ([88765d1](https://github.com/ajbeck/quorra/commit/88765d185e3f13ab25efb25348fc3eaff4876fc6))

## [0.1.1](https://github.com/ajbeck/quorra/compare/v0.1.0...v0.1.1) (2026-08-29)


### Bug Fixes

* **ci:** recover release asset publishing ([6a2a005](https://github.com/ajbeck/quorra/commit/6a2a00522b6f964c22a6c7c5a49498a50149769e))
* **ci:** set repository context for recovery ([5d5785b](https://github.com/ajbeck/quorra/commit/5d5785bc6e5bdbb44ff417ce6151746ace44e489))
* **release:** build distribution archives ([2c0edc5](https://github.com/ajbeck/quorra/commit/2c0edc5a723b6d9703f3324736eea309a68214db))
* **release:** scope distribution signing ([560f951](https://github.com/ajbeck/quorra/commit/560f95124d101f4b9af239031e5f05cba20daba5))

## 0.1.0 (2026-08-29)


### Features

* add AppModel state machine and root view with placeholders ([1718905](https://github.com/ajbeck/quorra/commit/17189056cdfbfdf3cfad2435a01142a67eb34af8))
* add AWSConfigINI ([cceab50](https://github.com/ajbeck/quorra/commit/cceab50b5ef3814b50f893d1763c20ce1f2d96d6))
* add BookmarkStorage helper and test target ([ebd6939](https://github.com/ajbeck/quorra/commit/ebd6939114fcc5b20f46823e5a55d86a07872e52))
* add split view profile layout ([cf458ef](https://github.com/ajbeck/quorra/commit/cf458ef8dab73002f29e48e188e6c162a49cafba))
* **app:** empty-state copy + accessibility polish ([d00fcb0](https://github.com/ajbeck/quorra/commit/d00fcb0ddc1223c69b61cfb0f76356741d012854))
* **app:** MainView NavigationSplitView shell + stub sidebar/detail ([bc7324c](https://github.com/ajbeck/quorra/commit/bc7324caf02ce3205ff50feb24bec83778687492))
* **app:** mode preference on AppModel + setup card ([64b54eb](https://github.com/ajbeck/quorra/commit/64b54ebdb3f72d77736c863481b853168d551d83))
* **app:** persist ManagedMode via ModePreferenceStorage ([e6c0827](https://github.com/ajbeck/quorra/commit/e6c082705283feaac90bd3f2f394d71578922cc4))
* **app:** profile + session detail panes (read path) ([6d06461](https://github.com/ajbeck/quorra/commit/6d064618551032479f8e7de8a99e61c8d64e3d27))
* **app:** ProfilesModel + sidebar classification ladder ([3c7c9f9](https://github.com/ajbeck/quorra/commit/3c7c9f9793043cef40c950ecb5c56cb893e8e330))
* **app:** real sidebar grammar with SSO outline + flat sections ([25e8be7](https://github.com/ajbeck/quorra/commit/25e8be7bcf910be1f271e0b1f0381a4155a507ba))
* **app:** save round-trip with confirmation flows ([cd61681](https://github.com/ajbeck/quorra/commit/cd616815b686a27013534220ee06da561adf9cf5))
* **app:** Settings scene with General + About tabs ([0a7eeb1](https://github.com/ajbeck/quorra/commit/0a7eeb1d958a24e8df4fd60cc8870405162a4e1c))
* **app:** wire RootView into quorraApp and remove Xcode-template ContentView ([1e31d9c](https://github.com/ajbeck/quorra/commit/1e31d9ca08265eecdd664ddf1024311c298d994f))
* automate signed DMG releases ([693e991](https://github.com/ajbeck/quorra/commit/693e9918331869d1012e2d99d0dae282045af5bb))
* **AWSConfigINI:** add Profile sso fields + LocalizedError conformance ([8b4bb9b](https://github.com/ajbeck/quorra/commit/8b4bb9b6200e501f01be0447c95cb197005e5c8c))
* **bookmarks:** add FolderPicker AppKit bridge ([b9e33ac](https://github.com/ajbeck/quorra/commit/b9e33aca37468b9d0520fe8ed80e0ac05a9d74e6))
* **error:** differentiate ErrorView per AppError case with recovery actions ([71e15a0](https://github.com/ajbeck/quorra/commit/71e15a05829cf68fc5a9fe470080a3d6a1cfe61c))
* flesh out imds detail view ([c0782fd](https://github.com/ajbeck/quorra/commit/c0782fd29d6239e40c6720a8d4cfdbe2d6ded536))
* **iam-identity-center:** phase A — package skeleton + Keychain actor ([7d0e297](https://github.com/ajbeck/quorra/commit/7d0e297d505d6452898d336f33cbdbfc4934ab1b))
* **iam-identity-center:** phase B — OIDCClient + Wire types ([0d97444](https://github.com/ajbeck/quorra/commit/0d974447e50440a2d3ec1f89ef6a2e432bd74c96))
* **iam-identity-center:** phase C — IdentityCenterService.signIn ([af0e7b4](https://github.com/ajbeck/quorra/commit/af0e7b4bc2fd2ff93809e113fd0bb8e0e2dbb495))
* **iam-identity-center:** phase D — CredentialsModel + app integration ([7a6662d](https://github.com/ajbeck/quorra/commit/7a6662d8b03396d0db59cdfcde4e07de5baa078d))
* **iam-identity-center:** phase E — sign-in panel success state + browser hop ([916072b](https://github.com/ajbeck/quorra/commit/916072b6804b41561351f5e54eae47888436ffaa))
* **iam-identity-center:** route OIDC through AWS SDK for Swift, per-region ([bc56094](https://github.com/ajbeck/quorra/commit/bc560942865df8b53451c1ee855280ed447e38d5))
* **iam-identity-center:** scope A1 — sign-out, status, event stream ([4ff1757](https://github.com/ajbeck/quorra/commit/4ff175788a9cc335567db71a63425c1850671334))
* **iam-identity-center:** scope A2 — silent refresh + live token ([32294fc](https://github.com/ajbeck/quorra/commit/32294fc5f9d9749fa9e8bc4ede5c417e75bafd6c))
* **iam-identity-center:** scope B chunk 1 — role-cred data + Portal wire ([f20d200](https://github.com/ajbeck/quorra/commit/f20d200529a13bf2d1a6881268a72bed8ed1743f))
* **iam-identity-center:** scope B chunk 2 — liveCredentials + single-flight ([90bcf65](https://github.com/ajbeck/quorra/commit/90bcf651f5f7e4c1e38ed77608a4b6b950354ca4))
* **iam-identity-center:** scope B chunk 3 — T_mint proactive timer ([6064dcc](https://github.com/ajbeck/quorra/commit/6064dcc079b8afec32f1c659a1e3422fa985516c))
* **iam-identity-center:** scope B chunk 4 — ProfileAuthStatus + status verb ([5727cae](https://github.com/ajbeck/quorra/commit/5727cae150ac0d0523eb87620ba55e6bdda96040))
* **iam-identity-center:** scope B chunk 5 — sign-out cascade ([4548708](https://github.com/ajbeck/quorra/commit/45487086f7802f311d3a0f4d64d2ccf5bd1b8448))
* **iam-identity-center:** scope B chunk 6a — mint events + model wiring ([150512d](https://github.com/ajbeck/quorra/commit/150512dd36592e70152403e708220423c6dc12f4))
* **iam-identity-center:** scope B chunk 6b — credentials reveal + profile status icon ([5ff6763](https://github.com/ajbeck/quorra/commit/5ff6763f2bd40985e6b446e0160500af2ae680ac))
* **main:** wire MainView to show the bookmarked folder's contents ([c51417c](https://github.com/ajbeck/quorra/commit/c51417cc1389e8fba31e5b324a35661b3cc9c7a3))
* present sso sign-in with auth session ([fb8ce2d](https://github.com/ajbeck/quorra/commit/fb8ce2db903f6b52f52e9be064314848b014ad3c))
* preserve legacy inline sso fields ([e577de3](https://github.com/ajbeck/quorra/commit/e577de3777650f9f2074fa81e1595a175d41c160))
* redesign navigation and add PR validation ([2368a53](https://github.com/ajbeck/quorra/commit/2368a53f26848d0dc3c6ccece3e326678887e559))
* refine credential imds controls ([73f8df1](https://github.com/ajbeck/quorra/commit/73f8df121009893ab3e87d7d9653dc20eba67561))
* restyle profile detail cards ([2e6a90f](https://github.com/ajbeck/quorra/commit/2e6a90f936a3700696e9a87fdcb0d46cd1c61c4f))
* scaffold app phase/error enums and fix bundle ID ([39ea25a](https://github.com/ajbeck/quorra/commit/39ea25a5b8e5c716cc2ca3b6e053cbaef31a567d))
* serve local imds endpoint ([631eaa4](https://github.com/ajbeck/quorra/commit/631eaa4484c5265cf4f27c680422291db88cff8a))
* **setup:** flesh out SetupView with welcome content and folder picker ([2eb8435](https://github.com/ajbeck/quorra/commit/2eb843570dadafd6a1b6b63e5c16ba21207badda))
* **setup:** redesign SetupView to match Manifest design ([7187ef8](https://github.com/ajbeck/quorra/commit/7187ef82bc4e8ddabfeeceeccc066fac38071cea))
* **setup:** replace non-standard folder modal alert with inline warning panel ([e063ed3](https://github.com/ajbeck/quorra/commit/e063ed37dcd76eaed4a93b89d1366e73042c1121))
* **sidebar:** add profile-first sidebar tabs ([f513506](https://github.com/ajbeck/quorra/commit/f513506d90b312f9372909cf97e001a08999bb98))
* **theme:** add Theme palette matching Claude Design brief ([8e39616](https://github.com/ajbeck/quorra/commit/8e39616abfffcc1ff81a1d6794bf8f4e6836f645))


### Bug Fixes

* add expired credential sign-in CTA ([be3f9ee](https://github.com/ajbeck/quorra/commit/be3f9ee3dbabfe5da89939348621834c4e603e2a))
* **ci:** provide release workflow repository context ([eca9bb4](https://github.com/ajbeck/quorra/commit/eca9bb409a05356157d3534074021191ee80959b))
* **iam-identity-center:** re-register OIDC client on invalidClient during sign-in ([f7d1bfb](https://github.com/ajbeck/quorra/commit/f7d1bfba23b754a386ad05ae56f322fb170c138d))
* **previews:** seed loaded app state deterministically ([fafe20d](https://github.com/ajbeck/quorra/commit/fafe20db2c2bbe6b5c3b606b5fbf03c780bbc341))
* **setup:** replace deprecated Text + concatenation with markdown interpolation ([8ad8288](https://github.com/ajbeck/quorra/commit/8ad82889015aaa6b90293b6e85d89c43dda35196))
* **setup:** use real user home when detecting the default AWS folder ([0bf089c](https://github.com/ajbeck/quorra/commit/0bf089c58cee8eda721ce48b627392997f2eab48))
* sleep / wait testing ([6634ac5](https://github.com/ajbeck/quorra/commit/6634ac5e50c8a9f1a8a9e1b01f168936dcfe0da3))
* stabilize package test helpers ([a5849fb](https://github.com/ajbeck/quorra/commit/a5849fbd48edbfcbf641d7d66d53edb1f4849bad))
* tighten credential command row ([a9071d6](https://github.com/ajbeck/quorra/commit/a9071d674ddc40d0a2bcf33c2eef9d108dae9822))
* unify credential detail states ([0b393ac](https://github.com/ajbeck/quorra/commit/0b393ac29d6df001b69fb8c351034ef60c6d25f9))
* update file locking tests ([37a5700](https://github.com/ajbeck/quorra/commit/37a57000d56aae9417ee14639273299e99a87d54))


### Miscellaneous Chores

* prepare repository for public release ([9ec73ad](https://github.com/ajbeck/quorra/commit/9ec73add8999c8ed379c747c14976f23161a899d))

## Changelog

All notable changes to Quorra are documented in this file.
