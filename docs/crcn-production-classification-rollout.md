# CRCN production rollout notes

Read-only production snapshot captured on 2026-11-04. This file records the
installation-specific rollout inputs; it contains no credential values.

## Production scope

The active production pipelines and stages are:

| Pipeline | ID | Active cards with a public, nonfailed incoming message in a live inbox (upper bound) |
|---|---|---:|
| Novas Reservas | `8849b2f1-0ca7-4d93-1234-567890abcdef` | 721 |
| Pós-Venda & Suporte CRCN | `a1111111-2222-3333-4444-555555555555` | 179 |
| Administrativo & Institucional | `b2222222-3333-4444-5555-666666666666` | 13 |

Stages:

- Novas Reservas: `35bcac15-5e85-4ffc-8666-7eba253e5396` Triagem & Qualificação (IA);
  `644d3ee0-fe3f-4db5-a3a1-3150d64e0c91` Cotação Apresentada;
  `75d30d95-3510-43fe-b9e4-b4ed1652ce55` Imóvel Escolhido / Negociação;
  `0432767f-285d-4d1d-a465-35edb2e4503d` Aguardando Pagamento (Humano);
  `6d370b73-4b5b-475d-9b9c-ad97d2953574` Reserva Confirmada;
  `32af77f0-e7b0-4642-92b4-c8a8411c8a48` Sem Vagas / Perdido.
- Pós-Venda & Suporte CRCN: `a1111111-0000-0000-0000-000000000001`
  Identificação da Reserva (IA); `a1111111-0000-0000-0000-000000000002`
  Em Atendimento (Suporte); `a1111111-0000-0000-0000-000000000003`
  Atendimento Finalizado.
- Administrativo & Institucional: `b2222222-0000-0000-0000-000000000001`
  Pré-Coleta do Assunto (IA); `b2222222-0000-0000-0000-000000000002`
  Em Análise Administrativa; `b2222222-0000-0000-0000-000000000003` Concluído.

Initial routing and stage semantics:

- Route a new or repeat stay inquiry to Novas Reservas based on the latest
  request. Use Triagem while dates, guest count, availability, or preferences
  are still being gathered; Cotação Apresentada after options/prices are sent;
  Imóvel Escolhido / Negociação after an explicit property choice; Aguardando
  Pagamento only after a checkout/payment instruction was sent; Reserva
  Confirmada only after an explicit confirmation in the exchange; Sem Vagas /
  Perdido only after explicit unavailability or the customer abandons/declines.
- Route support for an existing reservation, voucher, check-in, stay issue, or
  change request to Pós-Venda. Use Identificação da Reserva while the booking
  reference or booking context is being identified; Em Atendimento while the
  issue remains open; Atendimento Finalizado only after explicit resolution.
- Route owner, supplier, partnership, institutional, and administrative work
  to Administrativo. Use Pré-Coleta while the subject is still being clarified;
  Em Análise once the request is clear and being handled; Concluído only after
  explicit completion.
- Always classify the newest journey/request. Older purchases may disambiguate
  context but do not turn a fresh sales request into support. Customer claims
  alone do not establish payment or a confirmed booking; abstain when the
  exchange does not provide enough evidence.

Scope the first catalogs to the four operational inboxes:

- Airbnb (`0993068f-120f-4759-956c-64a24299f899`)
- Instagram (`d19fcdc8-a0e2-4b5f-906c-27df8ed61e9c`)
- WhatsApp fixo (`4326ada7-e853-477e-a1f4-fc41316a4de4`)
- WhatsApp principal (`5bbdb904-f7fa-4fc9-8109-1c95a80c9aaa`)

No Booking inbox was present in this production inventory. Add its inbox ID to
the three catalog scopes when it is connected. Exclude the `teste-qa-crcn-*`
inboxes from the first backfill.

There are 135 conversations with more than one active pipeline card. The
application job deliberately records `target_card_exists` and leaves those
cards unchanged; operators must review these conflicts in CRM before any
separate consolidation policy is considered. It must not close or overwrite an
existing card automatically because the cards can represent different booking
journeys for a repeat customer.

The three pipeline counts total 913 card-conversation pairs, not necessarily
913 distinct conversations. A latest-message timestamp tie or other runtime
gate can lower the number actually scheduled by backfill.

## Runtime prerequisites found

- The CRM web and Sidekiq containers use the same current immutable image
  digest. Their image is `ghcr.io/murilloimparavel/crcn-knowledge-crm`.
- The production database currently has zero classifier catalogs, results, or
  classifier states. The additive budget tables from this branch do not exist
  yet.
- The custom CRM web and Sidekiq containers do not currently have
  `EVO_AI_ENCRYPTION_KEY`; the Evo AI Core container does. `Ai::DecisionClient`
  therefore cannot report a usable OpenRouter credential in the custom CRM
  until the matching encryption key is added as a runtime secret to both CRM
  processes. Use the existing Evo AI Core secret; do not substitute the
  unrelated Rails `ENCRYPTION_KEY`, and never put either value in source or
  logs.
- No provider request was made during this inspection.

## Activation order

1. Merge the backend change into the production candidate branch and wait for
   its Ruby/security checks, regression suite, and immutable GHCR image build.
2. Configure the existing `EVO_AI_ENCRYPTION_KEY` as a Coolify runtime secret
   for both the custom CRM web and Sidekiq resources. Confirm the safe
   `provider_configured` status before any backfill.
3. Deploy the same immutable backend image to web and worker, run the additive
   database migration once, and verify health before proceeding.
4. Merge the frontend change to canonical `sofia-central-frontend` `main`;
   deploy its immutable `main-<SHA7>` image while preserving all required
   frontend runtime variables.
5. Publish a disabled/off catalog for each of the three pipelines, then publish
   reviewed observe-mode catalogs with criteria for all local stages and the
   three-pipeline routing scope. Publishing the initial target catalogs first
   satisfies the versioned routing-catalog dependency.
6. Start in observe mode with an initial cap of USD 0.01 per attempt, USD
   0.30 per day, and 30 distinct conversations per day. Backfill 10
   conversations per pipeline (30 total) and review the pipeline and stage for
   every result in the linked conversation. Keep automatic moves paused.
7. Require at least 95% exact pipeline-and-stage agreement across the 30 cases,
   with zero false `Reserva Confirmada` or `Aguardando Pagamento` outcomes,
   before scaling. The UI default is 25 conversations / USD 0.25 per day; the
   30-case cohort uses the corresponding 30 / USD 0.30 cap.
8. After the cohort passes, publish reviewed `auto` catalogs and raise the
   bounded backfill pace to at most 100 distinct conversations / USD 1.00 per
   day at the same USD 0.01 per-attempt reservation. Review skipped
   `target_card_exists` outcomes manually; those cards are intentionally not
   consolidated. The OpenRouter listing currently shows USD 0.042 per million
   input tokens and free output, but the runtime cap remains the authority for
   spend: [Jev 1.14 pricing](https://openrouter.ai/typesafe/jev-1.14/).

Pause all movement by clearing `automatic_moves_enabled`; disable online
classification by publishing `mode: off` for the relevant pipeline. Do not
rollback database tables destructively after reservations or audit records
exist; use a forward fix and restore the previous immutable application image
if runtime health fails.
