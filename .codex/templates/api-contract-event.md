# Event Contract: {{event_name}}

**Type:** Event (Kafka | RabbitMQ | SQS)
**Topic:** `{{domain}}.{{entity}}.{{action}}`
**Status:** Draft | Review | Approved

## Overview

{{when_published_and_who_consumes}}

## Event Schema

```json
{
  "eventId": "string - UUID v4",
  "eventType": "{{domain}}.{{entity}}.{{action}}",
  "timestamp": "ISO 8601",
  "version": "1.0",
  "payload": {
    "{{entity_id_field}}": "string",
    "{{data_field}}": {
      "{{field_1}}": "{{type}}",
      "{{field_2}}": "{{type}}"
    }
  },
  "metadata": {
    "correlationId": "string - Request trace ID",
    "causationId": "string - ID of event that caused this",
    "userId": "string - Actor who triggered the event"
  }
}
```

## Payload Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| {{entity_id_field}} | string | Yes | {{description}} |
| {{data_field}}.{{field_1}} | {{type}} | Yes | {{description}} |
| {{data_field}}.{{field_2}} | {{type}} | No | {{description}} |

## Producers

| Service | Trigger |
|---------|---------|
| {{service_name}} | {{what_triggers_event}} |

## Consumers

| Service | Action |
|---------|--------|
| {{consumer_service}} | {{what_it_does}} |
| {{consumer_service_2}} | {{what_it_does_2}} |

## Guarantees

- **Ordering:** Per-partition by {{partition_key}} | None
- **Delivery:** At least once | Exactly once
- **Retention:** {{duration}}
- **Idempotency:** Consumers must handle duplicates using {{idempotency_key}}

## Error Handling

**Dead Letter Queue:** `{{dlq_topic}}`

| Error Type | Action |
|------------|--------|
| Validation failure | Send to DLQ |
| Processing failure | Retry 3x, then DLQ |
| Transient error | Retry with backoff |

## Example

```json
{
  "eventId": "550e8400-e29b-41d4-a716-446655440000",
  "eventType": "{{domain}}.{{entity}}.{{action}}",
  "timestamp": "2024-01-15T10:30:00Z",
  "version": "1.0",
  "payload": {
    "{{entity_id_field}}": "user-123",
    "{{data_field}}": {
      "{{field_1}}": "example value",
      "{{field_2}}": 42
    }
  },
  "metadata": {
    "correlationId": "req-abc-123",
    "causationId": "evt-xyz-789",
    "userId": "admin-001"
  }
}
```

## Related

- **Stories:** {{story_ids}}
- **Decisions:** {{decision_ids}}
- **Related Events:** {{related_events}}
