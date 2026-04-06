# Exploration 2: Communication Buffer Agents (Paul Harrington)

## The Problem

Paul has communication mismatches with two different parts of his organization. The mismatch likely involves some combination of:

- Different abstraction levels (technical vs. business vs. executive)
- Different priorities (what matters to each stakeholder)
- Different communication styles (detail level, format, framing)
- Different vocabularies for the same concepts

## Proposed Architecture

A **pipeline** of role-conditioned agents, not a collaborative team:

```
                    ┌─────────────────────┐
Stakeholder A ───►  │  Intake Agent        │
(their style)       │  "Understands A"     │
                    │  Extracts: intent,   │
                    │  constraints, urgency │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Work Agent          │
                    │  "Works with Paul"   │◄──── Paul reviews,
                    │  Creates: tasks,     │      adjusts, approves
                    │  acceptance criteria, │
                    │  implementation plan  │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Output Agent        │
                    │  "Understands B"     │
                    │  Creates: updates,   │───► Stakeholder B
                    │  reports, materials  │     (their style)
                    │  in B's language     │
                    └─────────────────────┘
```

Each agent has a different **voice profile** — a system prompt conditioned on:
- Who the recipient is and what they care about
- What format/level of detail they expect
- What vocabulary and framing works for them
- What past communications have looked like (examples)

## Questions for Paul (Today's Call)

### Understanding the Mismatch
1. Who are the two groups you're communicating with? What are their roles?
2. Can you give me a concrete recent example where communication went sideways?
3. What does each group *actually need* from you? (vs. what they ask for)
4. What format do communications come in? (email, Slack, meetings, tickets, docs)

### Understanding the Pipeline
5. When you get a request/communication from Group A, what's your current process for turning it into work?
6. When you finish work, what's your current process for communicating it back to Group B?
7. Where does the most friction/misunderstanding happen — intake, execution, or output?

### Understanding Success
8. What would "this is working" look like for you?
9. Are there specific recurring communication patterns that trip you up?
10. Would it help more to have the agent rephrase *their* communications for you, or rephrase *your* work for them, or both?

## Implementation Approach

### Phase 1: Manual Pipeline (Skills)
Build each stage as a Claude Code skill. Paul runs them manually in sequence:
- `/intake` — paste a communication, get structured task extraction
- `/plan` — review extracted tasks with Paul, refine into actionable work
- `/communicate` — take completed work, generate stakeholder-appropriate output

### Phase 2: Connected Pipeline
Link the stages so output flows automatically, with Paul as the approval gate at each transition.

### Phase 3: Voice Profiles from Examples
Build the stakeholder voice profiles from real communication examples rather than abstract descriptions.

## Open Questions

- Is this really two separate pipelines (A→Paul, Paul→B) or one bidirectional flow?
- Does Paul need the agent to *understand the domain* or just *translate the communication style*?
- How much does the agent need to know about Paul's actual work to create good output?
- Should the intake agent push back / ask clarifying questions to stakeholders, or just interpret?
