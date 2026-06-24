# Code Change: {{resource_name}}

**Type:** REST
**Base Path:** `/api/v1/{{resource}}`
**Authentication:** Bearer Token | API Key | None
**Status:** Draft | Review | Approved

## Overview

{{api_description}}

## Endpoints

### POST /api/v1/{{resource}}

**Description:** Create a new {{resource}}

**Authentication:** Required

**Request:**

```json
{
  "{{field_1}}": "{{type}} (required) - {{description}}",
  "{{field_2}}": "{{type}} (optional) - {{description}}",
  "{{nested}}": {
    "{{subfield}}": "{{type}}"
  }
}
```

**Response (201 Created):**

```json
{
  "id": "string - Unique identifier",
  "{{field_1}}": "{{type}}",
  "{{field_2}}": "{{type}}",
  "createdAt": "ISO 8601 datetime"
}
```

**Errors:**

| Status | Code | Description |
|--------|------|-------------|
| 400 | VALIDATION_ERROR | Invalid request body |
| 401 | UNAUTHORIZED | Missing or invalid token |
| 409 | CONFLICT | Resource already exists |

---

### GET /api/v1/{{resource}}/{id}

**Description:** Retrieve a {{resource}} by ID

**Path Parameters:**
- `id` (string, required): Resource identifier

**Response (200 OK):**

```json
{
  "id": "string",
  "{{field_1}}": "{{type}}",
  "{{field_2}}": "{{type}}",
  "createdAt": "ISO 8601 datetime",
  "updatedAt": "ISO 8601 datetime"
}
```

**Errors:**

| Status | Code | Description |
|--------|------|-------------|
| 404 | NOT_FOUND | Resource does not exist |

---

### GET /api/v1/{{resource}}

**Description:** List {{resource}}s with pagination

**Query Parameters:**
- `page` (number, optional, default: 1): Page number
- `limit` (number, optional, default: 20, max: 100): Items per page
- `sort` (string, optional): Sort field
- `order` (string, optional): asc | desc

**Response (200 OK):**

```json
{
  "data": [...],
  "pagination": {
    "page": 1,
    "limit": 20,
    "total": 100,
    "totalPages": 5
  }
}
```

---

### PUT /api/v1/{{resource}}/{id}

**Description:** Update a {{resource}}

**Request:**

```json
{
  "{{field_1}}": "{{type}}",
  "{{field_2}}": "{{type}}"
}
```

**Response (200 OK):**

```json
{
  "id": "string",
  "{{field_1}}": "{{type}}",
  "updatedAt": "ISO 8601 datetime"
}
```

**Errors:**

| Status | Code | Description |
|--------|------|-------------|
| 404 | NOT_FOUND | Resource does not exist |
| 400 | VALIDATION_ERROR | Invalid request body |

---

### DELETE /api/v1/{{resource}}/{id}

**Description:** Delete a {{resource}}

**Response (204 No Content)**

**Errors:**

| Status | Code | Description |
|--------|------|-------------|
| 404 | NOT_FOUND | Resource does not exist |

## Data Models

### {{Resource}}

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | string | Yes | UUID v4 |
| {{field_1}} | {{type}} | Yes | {{description}} |
| {{field_2}} | {{type}} | No | {{description}} |
| createdAt | datetime | Yes | ISO 8601 |
| updatedAt | datetime | Yes | ISO 8601 |

### Enums

**{{EnumName}}:**
- `{{value_1}}` - {{description}}
- `{{value_2}}` - {{description}}

## Rate Limiting

| Endpoint | Limit | Window |
|----------|-------|--------|
| POST /{{resource}} | 100 | 1 hour |
| GET /{{resource}} | 1000 | 1 hour |

## Related

- **Stories:** {{story_ids}}
- **Decisions:** {{decision_ids}}
