---
description: Define code changes and interface specifications
argument-hint: [task-path] [--type=rest|graphql|grpc|event]
allowed-tools: Read, Write, Glob, Grep, AskUserQuestion, Task, mcp__context7__resolve-library-id, mcp__context7__query-docs
---

# Code Changes

Define interfaces, API endpoints, and data contracts.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user
- `--type=<type>`: Contract type (rest, graphql, grpc, event)

## Prerequisites

- Task folder must exist
- User stories and design decisions should be defined
- Only available in **full mode**

Check mode in `{task_path}/README.md`. If minimal mode, inform user this step is skipped.

## Execution

### 1. Identify Interfaces

Review artifacts to find interfaces that need contracts:
- `{task_path}/user-stories/*.md` - Features requiring APIs
- `{task_path}/design-decisions/*.md` - Architectural choices
- `{task_path}/research/*.md` - Existing API patterns

Types of contracts:
- **REST endpoints** - HTTP APIs
- **GraphQL schemas** - Query/Mutation definitions
- **gRPC services** - Protobuf definitions
- **Event schemas** - Message queue contracts
- **Internal interfaces** - Module boundaries

### 2. Gather Requirements

For each interface, determine:
- Who consumes it? (frontend, mobile, other services)
- What data is exchanged?
- What are the error cases?
- Authentication/authorization requirements?
- Rate limiting or quotas?

### 3. Create Contract Files

Create `{task_path}/code-changes/{name}.md`:

#### REST Code Change

```markdown
# Code Change: [Resource Name]

**Type:** REST
**Base Path:** `/api/v1/[resource]`
**Authentication:** Bearer Token | API Key | None
**Status:** Draft | Review | Approved

## Overview

[What this API does and who uses it]

## Endpoints

### POST /api/v1/[resource]

**Description:** Create a new [resource]

**Authentication:** Required

**Request:**

```json
{
  "field1": "string (required) - Description",
  "field2": "number (optional) - Description",
  "nested": {
    "subfield": "string"
  }
}
```

**Response (201 Created):**

```json
{
  "id": "string - Unique identifier",
  "field1": "string",
  "field2": "number",
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

### GET /api/v1/[resource]/{id}

**Description:** Retrieve a [resource] by ID

**Path Parameters:**
- `id` (string, required): Resource identifier

**Response (200 OK):**

```json
{
  "id": "string",
  "field1": "string",
  ...
}
```

**Errors:**

| Status | Code | Description |
|--------|------|-------------|
| 404 | NOT_FOUND | Resource does not exist |

---

### GET /api/v1/[resource]

**Description:** List [resources] with pagination

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

## Data Models

### [Resource]

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | string | Yes | UUID v4 |
| field1 | string | Yes | ... |
| field2 | number | No | ... |
| createdAt | datetime | Yes | ISO 8601 |
| updatedAt | datetime | Yes | ISO 8601 |

### Enums

**Status:**
- `active` - Resource is active
- `inactive` - Resource is disabled
- `deleted` - Soft deleted

## Rate Limiting

| Endpoint | Limit | Window |
|----------|-------|--------|
| POST /resource | 100 | 1 hour |
| GET /resource | 1000 | 1 hour |

## Related

- **Stories:** US-XXX, US-YYY
- **Decisions:** DD-XXX
```

#### Event Contract

```markdown
# Event Contract: [Event Name]

**Type:** Event (Kafka/RabbitMQ/SQS)
**Topic:** `domain.entity.action`
**Status:** Draft | Review | Approved

## Overview

[When this event is published and who consumes it]

## Event Schema

```json
{
  "eventId": "string - UUID",
  "eventType": "domain.entity.action",
  "timestamp": "ISO 8601",
  "version": "1.0",
  "payload": {
    "entityId": "string",
    "data": { ... }
  },
  "metadata": {
    "correlationId": "string",
    "causationId": "string"
  }
}
```

## Producers

- [Service that publishes this event]

## Consumers

- [Service that subscribes] - [What it does with the event]

## Guarantees

- **Ordering:** [Per-partition | None]
- **Delivery:** [At least once | Exactly once]
- **Retention:** [Duration]
```

### 4. Update Code Changes README

Update `{task_path}/code-changes/README.md`:

```markdown
# Code Changes

Interface definitions and API specifications.

## Contents

| Name | Type | Status |
|------|------|--------|
| Users API | REST | Draft |
| Auth Events | Event | Draft |

## API Map

### Public APIs
- [users.md](users.md) - User management

### Internal APIs
- [...]

### Events
- [auth-events.md](auth-events.md) - Authentication events
```

## Contract Guidelines

Good contracts:
- [ ] Define all request/response fields with types
- [ ] Document all error cases
- [ ] Include authentication requirements
- [ ] Specify validation rules
- [ ] Are versioned
- [ ] Match existing API patterns in the codebase

## 5. Review Artifacts

Launch the reviewer agent to validate code changes:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: contracts
    Task path: {task_path}
    Artifacts to review: {task_path}/code-changes/*.md (exclude README)

    Review the code changes and report any issues.
```

If the reviewer finds blockers (🔴), fix before proceeding.

## Example Usage

```
/saha:contracts docs/tasks/task-01-auth
/saha:contracts --type=rest
```
