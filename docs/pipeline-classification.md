# Pipeline classification operations

The classifier observes public conversation messages and recommends both a pipeline and a stage. Inbound customer messages start a debounced cycle; public outbound messages invalidate the previous snapshot and may start another cycle. Private, historical imports, deleted, failed, and revoked messages do not qualify as current evidence; authenticated Stays Bridge events with `external_created_at` do. The provider receives only the bounded, minimized snapshot generated from the approved catalog, with at most 20 recent messages under the request byte limit. The current CRM card and stage are never sent as classification evidence.

## Modes and movement gate

- `off`: no lifecycle scheduling.
- `observe`: persist a typed recommendation or abstention; never move a card.
- `auto`: allow a fresh `stage_recommended` result to reach the application job.

An automatic move additionally requires the installation setting `PIPELINE_CLASSIFICATION_SETTINGS.automatic_moves_enabled` to be `true`. This setting defaults to false. The same setting object must retain the reviewed online authorization and budget fields used by `PipelineClassification::Budget`; never replace that object with only one flag. Set the movement flag to false for an immediate installation-wide pause. Publishing a pipeline catalog in `off` mode cancels or invalidates in-flight classifications for that pipeline.

The application job revalidates catalog revision, result freshness, source card, target pipeline and stage, and installation pause state while holding locks in pipeline → conversation → classifier state → result → card order. Repeated jobs are idempotent. Same-pipeline changes are recorded as `automated`; cross-pipeline changes as `cross_pipeline`. Audit notes contain the classification result ID and no conversation text. A destination card already present causes a safe skip.

## Configuration API

All write operations require a human operator with `pipelines.update`; projection reads remain available to the existing CRM service contract.

- `GET /api/v1/pipelines/:pipeline_id/classification_catalog`
- `PUT /api/v1/pipelines/:pipeline_id/classification_catalog` with `expected_hash`
- `POST /api/v1/pipelines/:pipeline_id/classification_catalog/preview`
- `POST /api/v1/pipelines/:pipeline_id/classification_catalog/publish`
- `GET /api/v1/pipelines/:pipeline_id/classification_catalog/results?limit=50&before_id=<result_uuid>` (omit `before_id` for the newest page)
- `POST /api/v1/pipelines/:pipeline_id/classification_catalog/backfill` with `limit` (1–100) and optional `after_id`
- `GET /api/v1/pipelines/:pipeline_id/classification_catalog/runtime`
- `PATCH /api/v1/pipelines/:pipeline_id/classification_catalog/runtime` with `automatic_moves_enabled` (requires `installation_configs.manage`)
- `POST /api/v1/pipelines/:pipeline_id/classification_catalog/runtime/reset_provider` (requires `installation_configs.manage`)
- `GET /api/v1/pipelines/:pipeline_id/classification_catalog/projection`

Configure `classification.routing_pipeline_ids` to include the source and permitted destination pipelines. A destination contributes only stages from its own latest published catalog. Publish target catalogs before source catalogs that reference them. Results returns bounded decision metadata only; it excludes message text, PII, provider payloads, and credentials.

Backfill makes one bounded pass over active conversation cards in the selected pipeline, uses the latest unambiguous incoming message, and returns `next_cursor`/`done` so an operator can continue in further batches. The regular scheduler applies the usual debounce, authorization, budget, snapshot, and provider gates. A current result or pending cycle is not re-enqueued by repeating the same batch.

## Monitoring and recovery

Inspect result `status`, `reason`, confidence values, `decision.application`, cost, and latency in the paginated catalog dialog or results API; each result links to its conversation for human review. Low-confidence, mismatched, invalid, stale, or no-candidate decisions do not move cards. A skipped application records a bounded reason. Provider circuit status exposes only counters, a safe failure code, and reset state. A 401 requires an operator reset after correcting the runtime credential. The scheduler recovers due evaluation jobs and classified auto applications that were not enqueued successfully.

To pause movement, set `automatic_moves_enabled=false` through the runtime endpoint. To stop one pipeline, publish its catalog with `mode=off` and `enabled=false`. To restore a previous classification behavior, publish a reviewed catalog revision; historical results and movement records remain available. Do not rotate credentials by editing catalog profiles; configure the provider key only as a runtime secret.

## Retention and billing

Budget reservations are installation-scoped, bounded per attempt, daily by cost and conversation count, and preserve unknown in-flight charges for reconciliation. Conversation snapshots and results are not raw transcripts. The configured retention window governs classifier results, message-event receipts, and budget-day conversation identifiers; preserve movement audit rows independently.
