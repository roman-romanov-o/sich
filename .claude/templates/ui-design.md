# UI Design: {{component_or_page_name}}

**Status:** Draft | In Progress | Review | Approved
**Phase:** Optional (Pre-Implementation)
**Skill:** `/frontend-design`

<!--
This is an OPTIONAL phase for tasks involving frontend work.
Use when creating new UI components, pages, or redesigning existing interfaces.
Skip for backend-only or CLI tasks.
-->

## Overview

**What we're designing:** {{brief_description}}
**Target users:** {{who_will_use_this}}
**Key interaction:** {{primary_user_action}}

## Design Context

### Existing Patterns

<!-- Reference existing UI patterns in the codebase -->

| Pattern | Location | Reuse? |
|---------|----------|--------|
| {{pattern_name}} | `{{file_path}}` | Yes/No/Adapt |

### Brand/Style Constraints

<!-- Any existing style guides, color schemes, or design systems -->

- **Colors:** {{primary_colors}}
- **Typography:** {{font_family}}
- **Spacing:** {{spacing_system}}
- **Components:** {{existing_component_library}}

## Design Requirements

### Must Have

- [ ] {{essential_ui_requirement_1}}
- [ ] {{essential_ui_requirement_2}}
- [ ] {{essential_ui_requirement_3}}

### Should Have

- [ ] {{important_ui_requirement}}

### Could Have

- [ ] {{nice_to_have_ui_feature}}

## Aesthetic Direction

<!--
Choose ONE direction. The /frontend-design skill will use this to guide implementation.
Options: bold-modern, soft-organic, brutalist, neo-retro, minimalist-functional
-->

**Direction:** {{chosen_aesthetic}}

**Why this direction:**
{{rationale_for_aesthetic_choice}}

### Visual Characteristics

- **Color palette:** {{specific_colors_or_mood}}
- **Shape language:** {{rounded_sharp_organic}}
- **Motion:** {{animation_style_if_any}}
- **Density:** {{compact_spacious}}

## Component Breakdown

### Component 1: {{component_name}}

**Purpose:** {{what_it_does}}

**States:**
- Default: {{appearance}}
- Hover: {{appearance}}
- Active: {{appearance}}
- Disabled: {{appearance}}
- Error: {{appearance}}

**Responsive behavior:**
- Desktop (1024px+): {{layout}}
- Tablet (768-1023px): {{layout}}
- Mobile (<768px): {{layout}}

---

### Component 2: {{component_name}}

**Purpose:** {{what_it_does}}

**States:**
- Default: {{appearance}}
- Hover: {{appearance}}

---

## User Flows

### Primary Flow: {{flow_name}}

```
[Step 1: {{user_action}}]
    ↓
[Step 2: {{system_response}}]
    ↓
[Step 3: {{user_action}}]
    ↓
[Success: {{outcome}}]
```

### Error Flow: {{error_scenario}}

```
[Step 1: {{user_action}}]
    ↓
[Error: {{what_went_wrong}}]
    ↓
[Recovery: {{how_user_recovers}}]
```

## Accessibility Requirements

- [ ] Color contrast ratio ≥ 4.5:1 for text
- [ ] Keyboard navigable (Tab, Enter, Escape)
- [ ] Screen reader compatible (ARIA labels)
- [ ] Focus indicators visible
- [ ] {{additional_a11y_requirement}}

## Technical Constraints

<!-- Framework, build system, or technical limitations -->

- **Framework:** {{react_vue_vanilla_etc}}
- **CSS approach:** {{tailwind_modules_styled_components}}
- **Animation library:** {{framer_motion_css_none}}
- **Browser support:** {{browsers}}

## Design Artifacts

<!-- Links to mockups, wireframes, or design files -->

| Artifact | Status | Link/Location |
|----------|--------|---------------|
| Wireframe | {{status}} | {{link}} |
| High-fidelity mockup | {{status}} | {{link}} |
| Interactive prototype | {{status}} | {{link}} |

## Implementation Notes

<!-- Guidance for the implementation phase -->

### Code Generation

When running `/frontend-design`:
1. Reference this document for requirements
2. Use the aesthetic direction specified above
3. Ensure all states are implemented
4. Follow accessibility checklist

### Files to Create/Modify

| File | Purpose |
|------|---------|
| `{{component_path}}` | {{description}} |
| `{{styles_path}}` | {{description}} |

## Review Checklist

Before marking as Approved:

- [ ] All must-have requirements addressed
- [ ] Aesthetic direction clearly defined
- [ ] All component states documented
- [ ] Accessibility requirements listed
- [ ] Technical constraints verified with implementation plan

## Related

- **User Stories:** {{story_ids}}
- **Implementation Phase:** {{phase_id}}
- **Design Decisions:** {{dd_ids}}
