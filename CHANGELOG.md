# Changelog

## 1.0.0 (2026-08-27)


### Features

* add AppModel state machine and root view with placeholders ([fc75671](https://github.com/ajbeck/quorra/commit/fc756713443f5d6ae7f79e131477ccf1590060b7))
* add AWSConfigINI ([350be2b](https://github.com/ajbeck/quorra/commit/350be2bdb8c4f3fc4b76ca067ce8efb703673c57))
* add BookmarkStorage helper and test target ([4dac46b](https://github.com/ajbeck/quorra/commit/4dac46b8ed513f79a6d39714c51f567b7fb44ac9))
* add split view profile layout ([a76ddf7](https://github.com/ajbeck/quorra/commit/a76ddf70e28d697f06c7ff0f538de177a68f0298))
* **app:** empty-state copy + accessibility polish ([1bedbee](https://github.com/ajbeck/quorra/commit/1bedbee513cd22624bda5c9647e4f673f58a250a))
* **app:** MainView NavigationSplitView shell + stub sidebar/detail ([b590507](https://github.com/ajbeck/quorra/commit/b590507cf1ac96ffd37f88e7539386ad70672320))
* **app:** mode preference on AppModel + setup card ([7ae558a](https://github.com/ajbeck/quorra/commit/7ae558a5707abaaf66251b529266d376ac3ee1ba))
* **app:** persist ManagedMode via ModePreferenceStorage ([3a8ae85](https://github.com/ajbeck/quorra/commit/3a8ae8561d7c99856708c6599f1346a746af8ef8))
* **app:** profile + session detail panes (read path) ([c04b458](https://github.com/ajbeck/quorra/commit/c04b458becc1eaba9c13d2c5ca24a4edc88f8b8b))
* **app:** ProfilesModel + sidebar classification ladder ([e3fde0d](https://github.com/ajbeck/quorra/commit/e3fde0d8e67657aaec116e26dfc3180f152c182b))
* **app:** real sidebar grammar with SSO outline + flat sections ([750f191](https://github.com/ajbeck/quorra/commit/750f19136558607ff4dfc50d2233c1e47928c46e))
* **app:** save round-trip with confirmation flows ([bf32ffd](https://github.com/ajbeck/quorra/commit/bf32ffd5f3144ef64ecf5da4e0bd6dd4e70d063b))
* **app:** Settings scene with General + About tabs ([7db3907](https://github.com/ajbeck/quorra/commit/7db3907ddda995754f77fa06c0d1b9736f12ef76))
* **app:** wire RootView into quorraApp and remove Xcode-template ContentView ([677e416](https://github.com/ajbeck/quorra/commit/677e41665480f0b9463cfb02e7e34cef02b4cc1c))
* automate signed DMG releases ([89a380d](https://github.com/ajbeck/quorra/commit/89a380da1a6b4dd3be3b225327c08354a1378d3a))
* **AWSConfigINI:** add Profile sso fields + LocalizedError conformance ([83b2367](https://github.com/ajbeck/quorra/commit/83b2367dae70a307ef2aa9eddbdf9cd878ebcfb6))
* **bookmarks:** add FolderPicker AppKit bridge ([72aaa24](https://github.com/ajbeck/quorra/commit/72aaa24d2dc233634efa0f7e5fb6dc96d34b4903))
* **error:** differentiate ErrorView per AppError case with recovery actions ([3d20e2b](https://github.com/ajbeck/quorra/commit/3d20e2b360fb3c900caed436de47ff59b661326d))
* flesh out imds detail view ([104a42f](https://github.com/ajbeck/quorra/commit/104a42f099ecf0fdec78c571eea2e9cc07959a87))
* **iam-identity-center:** phase A — package skeleton + Keychain actor ([2b10c01](https://github.com/ajbeck/quorra/commit/2b10c013de04ecfb85f361d7d6298935694ccc39))
* **iam-identity-center:** phase B — OIDCClient + Wire types ([74841ed](https://github.com/ajbeck/quorra/commit/74841eda6d31835055e370d043cb225caf66a179))
* **iam-identity-center:** phase C — IdentityCenterService.signIn ([74e6408](https://github.com/ajbeck/quorra/commit/74e64088121a1c1c2f4d2cb2f166aff8811f9b5d))
* **iam-identity-center:** phase D — CredentialsModel + app integration ([cc696f7](https://github.com/ajbeck/quorra/commit/cc696f780883cf8bec2b579f90f978f5ffe98016))
* **iam-identity-center:** phase E — sign-in panel success state + browser hop ([fd67405](https://github.com/ajbeck/quorra/commit/fd6740567a01fdf74f37810ce4f69d654a70f63c))
* **iam-identity-center:** route OIDC through AWS SDK for Swift, per-region ([817cce3](https://github.com/ajbeck/quorra/commit/817cce3177bb16439ce2569ea3ccc3d346c87ca3))
* **iam-identity-center:** scope A1 — sign-out, status, event stream ([3093e42](https://github.com/ajbeck/quorra/commit/3093e42c3d7be90e5659795f27e839b6d57fd43c))
* **iam-identity-center:** scope A2 — silent refresh + live token ([17e6812](https://github.com/ajbeck/quorra/commit/17e68123ec3d929bb91cf4bdd4f94ea41fbd95a3))
* **iam-identity-center:** scope B chunk 1 — role-cred data + Portal wire ([3dcc400](https://github.com/ajbeck/quorra/commit/3dcc400a944cc190708fda5b114af0783ee5ca29))
* **iam-identity-center:** scope B chunk 2 — liveCredentials + single-flight ([5727d3a](https://github.com/ajbeck/quorra/commit/5727d3ac02298ae24e1bf461944de995f7f55e94))
* **iam-identity-center:** scope B chunk 3 — T_mint proactive timer ([42e898a](https://github.com/ajbeck/quorra/commit/42e898a274e08a2fe1d0e0e2d7bfa1c2b37caacb))
* **iam-identity-center:** scope B chunk 4 — ProfileAuthStatus + status verb ([c22d144](https://github.com/ajbeck/quorra/commit/c22d1448e50ad95e817d73881d8b878ad511f476))
* **iam-identity-center:** scope B chunk 5 — sign-out cascade ([8009c58](https://github.com/ajbeck/quorra/commit/8009c58343795307438fcdd870cf7dcbe1cad5c7))
* **iam-identity-center:** scope B chunk 6a — mint events + model wiring ([813a90b](https://github.com/ajbeck/quorra/commit/813a90b71e228f80559cc8bea4a724ab0e9bcbf7))
* **iam-identity-center:** scope B chunk 6b — credentials reveal + profile status icon ([23a9f9e](https://github.com/ajbeck/quorra/commit/23a9f9e1ba02625b507b183addffad850fbd87f0))
* **main:** wire MainView to show the bookmarked folder's contents ([b68459a](https://github.com/ajbeck/quorra/commit/b68459a52c54b6d5303e2cb7d88ecc8a4d901632))
* present sso sign-in with auth session ([fb6b030](https://github.com/ajbeck/quorra/commit/fb6b030069764085862c886cba840174af475e3e))
* preserve legacy inline sso fields ([625a83d](https://github.com/ajbeck/quorra/commit/625a83df194594677226ce8d4d5a17919ec7d7ef))
* redesign navigation and add PR validation ([9e3478e](https://github.com/ajbeck/quorra/commit/9e3478ef2ba49e42042736f25a5f2eb9a3dcd55d))
* refine credential imds controls ([d8f92a6](https://github.com/ajbeck/quorra/commit/d8f92a646fdd2282771adf3145d1514a4dda80ff))
* restyle profile detail cards ([a682797](https://github.com/ajbeck/quorra/commit/a6827972d3dfc0649cc181679e2dcb58d475dbe3))
* scaffold app phase/error enums and fix bundle ID ([e0424e3](https://github.com/ajbeck/quorra/commit/e0424e3cb20c372471b9a1f6514c69088e72c882))
* serve local imds endpoint ([6876d34](https://github.com/ajbeck/quorra/commit/6876d3459faa9577ab09e1c458591baeef3c29f9))
* **setup:** flesh out SetupView with welcome content and folder picker ([d25f03f](https://github.com/ajbeck/quorra/commit/d25f03f532ef2137f3fc455bc2107abf8b1b541e))
* **setup:** redesign SetupView to match Manifest design ([e0d88bf](https://github.com/ajbeck/quorra/commit/e0d88bf5cb666021260c12bb5390137911635d40))
* **setup:** replace non-standard folder modal alert with inline warning panel ([ef093ac](https://github.com/ajbeck/quorra/commit/ef093ac27b0514189a311c385d6395af9de7fb72))
* **sidebar:** add profile-first sidebar tabs ([e9ecfb0](https://github.com/ajbeck/quorra/commit/e9ecfb0c061c1784a11e5076dd87a71e53fdbe80))
* **theme:** add Theme palette matching Claude Design brief ([4d8e953](https://github.com/ajbeck/quorra/commit/4d8e953e4e1c72ec43b93b07b6f46eaee863c483))


### Bug Fixes

* add expired credential sign-in CTA ([1beff4d](https://github.com/ajbeck/quorra/commit/1beff4d2fee84bf3d26a1d299454da8ab0b467da))
* **iam-identity-center:** re-register OIDC client on invalidClient during sign-in ([15677bb](https://github.com/ajbeck/quorra/commit/15677bb3b85d5318517f1528903086e88af233cb))
* **previews:** seed loaded app state deterministically ([3e371ee](https://github.com/ajbeck/quorra/commit/3e371ee668ca42650f20692474b47a79a8005145))
* **setup:** replace deprecated Text + concatenation with markdown interpolation ([1ddf9b6](https://github.com/ajbeck/quorra/commit/1ddf9b6080fa2190ecd3727f082f3a5d455b3c7d))
* **setup:** use real user home when detecting the default AWS folder ([0d26421](https://github.com/ajbeck/quorra/commit/0d26421560fde803372f6f9d359d59cc5d05ade0))
* sleep / wait testing ([f85f64b](https://github.com/ajbeck/quorra/commit/f85f64b769132739b77f4ca6e7212a2a99824a92))
* stabilize package test helpers ([ac3a51e](https://github.com/ajbeck/quorra/commit/ac3a51e2677ae7e81b8c967c8bd14725e4245df0))
* tighten credential command row ([0918ad2](https://github.com/ajbeck/quorra/commit/0918ad22d756c89f69c57daf96d0b3d22ccd50f1))
* unify credential detail states ([bbcd4ef](https://github.com/ajbeck/quorra/commit/bbcd4ef484ecbbdab47a005c0a56853b53775f4f))
* update file locking tests ([760854a](https://github.com/ajbeck/quorra/commit/760854a81a2c6673d6d193939aa6a854415774db))

## Changelog

All notable changes to Quorra are documented in this file.
