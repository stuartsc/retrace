# AAC container-padding validation — 13 November 2026

This V23-compatible candidate ports the reviewed compactor, legacy writer option and native tests from ef3eeb2. No schema, codec, sample, priming or timing change; existing audio is untouched. Option stays default off until tests pass. V32 chunk-media implementation is not included.

The isolated `.aac-validation` package contains exact copies of production Shared, the two production audio writer/compactor files, native XCTest source and authored fixtures. It has no mocks, recording devices, UI or external dependencies. Its clean component checks do not constitute whole-app integration or installed acceptance. Source hashes are retained. A final integrated clean build remains required before rollout.

Clean native component tests passed:5tests,0skips,0failures. The10s/15s/21.248s authored clips saved39.719%/30.578%/23.901% respectively; exact packets, codec cookie, priming/remainder, decoded PCM and seeks matched. Unknown/malformed containers and symlinks remained unchanged. Denied atomic staging preserved the valid original. All source copies matched before/after and matched production. Receipts retained under `docs/fixtures/repair-20261113-aac`. Full-app integration and installed measurements remain pending; option remains off.


The later audio-delivery source branch selects this option explicitly for newly
created production writers through one immutable App policy, while the component
initializer and private test containers still default off. Integrated build/test
and rollout state are tracked separately in
[audio-delivery integration](audio-delivery-integration-20261113.md).
