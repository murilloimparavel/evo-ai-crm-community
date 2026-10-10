# WhatsApp Cloud template definitions and publications

The Settings page has a separate **WhatsApp Cloud · Definições** scope. A definition is CRM-owned content and is not sendable until Meta approves a publication. Generic and e-mail templates continue to use the existing `message_templates` catalog.

## Data model

- `whatsapp_template_definitions` stores the reusable name, language, requested category, body, Meta components, variables, and active flag.
- `whatsapp_template_publications` stores one WABA-specific submission and its external Meta ID, raw/normalized status, Meta category, quality, rejection reason, timestamps, and sanitized operational error.
- Definition names are unique per language. A unique index on definition + WABA deduplicates target submissions. A second partial unique index prevents duplicate external IDs within one WABA.
- Credentials remain on the existing WhatsApp channel configuration and are never copied into these records.

The existing chat and automation readers still consume channel-bound `message_templates` rows. After a successful submission, the publication service propagates the synchronized template into channels attached to the same WABA. The status webhook updates every such local copy and the corresponding WABA publication. The send resolver rejects Cloud templates unless their Meta status is approved.

## API

- `GET /api/v1/whatsapp_template_definitions` lists definitions. Optional filters: `search`, `category`, `language`, `waba_id`, and publication `status`.
- `GET /api/v1/whatsapp_template_definitions/targets` returns WABA IDs and safe inbox identity fields for authorized users; credentials are excluded.
- `POST /api/v1/whatsapp_template_definitions` creates a definition from a `definition` object.
- `PUT /api/v1/whatsapp_template_definitions/:id` edits a definition.
- `POST /api/v1/whatsapp_template_definitions/:id/publish` accepts explicit unique `waba_ids`.

Submissions with an ambiguous timeout are marked `submission_unknown` and are not blindly repeated. A later catalog sync can reconcile the publication by WABA, template name, and language, then persist Meta's external ID and status. Operators should sync the WABA catalog before retrying an ambiguous result.

After a definition has been submitted, its name, language, category, components, variables, and content are locked. Create a new definition to make a changed template, so the stored definition cannot drift away from the versions Meta is reviewing or has approved.

## Current limits

The editor supports text header/body/footer and existing button types. Variables are supported in the body, require an explicit example, and positional markers must be consecutive from `{{1}}`; named and positional markers cannot be mixed. Dynamic URL-button variables are rejected because the outbound payload contract is not implemented. Media headers and authentication/OTP are not offered in this flow because their complete Meta upload/example and outbound send contracts are not implemented here. Publishing requires an already configured Cloud channel for each WABA. No Meta integration test should use a customer recipient.

## Verification runbook

Run from the backend checkout with the Ruby version in `.ruby-version` / `Gemfile.lock` and dependencies installed:

```sh
bundle exec rspec \
  spec/models/whatsapp_template_publication_spec.rb \
  spec/services/whatsapp/template_publication_service_spec.rb \
  spec/services/message_templates/send_resolver_whatsapp_cloud_spec.rb \
  spec/jobs/webhooks/whatsapp_events_job_spec.rb \
  spec/services/whatsapp/providers/whatsapp_cloud_service_spec.rb \
  spec/services/whatsapp/send_on_whatsapp_service_spec.rb \
  spec/requests/api/v1/whatsapp_template_definitions_spec.rb
RAILS_ENV=test bundle exec rails db:migrate
```

Run the frontend checks from the canonical frontend checkout:

```sh
pnpm exec vitest run \
  src/components/channels/settings/TemplateFormModal.spec.tsx \
  src/pages/Customer/Settings/MessageTemplates/__tests__/MessageTemplates.spec.tsx \
  src/services/channels/__tests__/messageTemplatesService.spec.ts \
  src/services/messageTemplates/__tests__/whatsappCloudTemplateService.spec.ts
pnpm exec eslint src/components/channels/settings/TemplateFormModal.tsx \
  src/pages/Customer/Settings/MessageTemplates/MessageTemplates.tsx \
  src/services/channels/messageTemplatesService.ts \
  src/services/messageTemplates/whatsappCloudTemplateService.ts
pnpm run build
```

For end-to-end Meta QA, use only test WABAs and a test recipient: connect two Cloud inboxes to one WABA and one inbox to a second WABA; publish to the first WABA and verify it is submitted once and visible in both sibling inboxes; publish the same definition to the second WABA and verify a different publication/Meta ID; repeat a publish request and confirm it does not create another Meta template; deliver pending/approved/rejected status updates and verify only the matching WABA + Meta ID changes; confirm the chat and automation selectors expose approved templates for the sending inbox and reject pending, inactive, global-generic, and other-WABA templates. Do not run this checklist against production recipients.
