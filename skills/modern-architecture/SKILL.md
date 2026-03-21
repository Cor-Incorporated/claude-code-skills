---
name: modern-architecture
description: "Design features using DDD + TDD + Clean Architecture + Event-Driven + API-First patterns for TypeScript, Python, and Go. Use when: designing features with domain complexity (Entities, Value Objects, Aggregates), structuring projects with layer separation, defining Bounded Contexts, applying Outside-In TDD, designing CQRS or Event Sourcing, creating API contracts before implementation, starting a new project architecture. Trigger phrases: DDD, TDD, clean architecture, hexagonal, ports and adapters, CQRS, event sourcing, API-first, domain model, bounded context. Do NOT use for: simple scripts, one-off utilities, UI-only components without domain logic, or CRUD-only endpoints with no business rules."
allowed-tools: [Read, Grep, Glob, WebSearch, AskUserQuestion]
---

# Modern Architecture

DDD + TDD + Clean Architecture + Event-Driven + API-First for TS/Python/Go.

## Decision Tree

```
New feature or module?
|
+- Complex business rules?
|  YES -> DDD Tactical Patterns (references/ddd-tactical.md)
|  |
|  +- Different stakeholders use different terms for same concept?
|  |  YES -> Bounded Contexts (references/ddd-strategic.md)
|  |
|  +- External system integration?
|  |  YES -> Anti-Corruption Layer (references/ddd-strategic.md)
|  |
|  +- Read/write patterns differ significantly?
|     YES -> CQRS (references/event-driven.md)
|
+- Has API surface?
|  YES -> Contract-First: schema before code (references/api-first.md)
|
+- Needs async/real-time communication?
|  YES -> Event-Driven (references/event-driven.md)
|
+- Any of the above?
   YES -> Clean Architecture layers (references/clean-architecture.md)
   NO  -> Simple module, skip this skill
```

<important if="applying Outside-In TDD with DDD or starting a new feature with domain discovery">
## Core Workflow: Outside-In Development

### 1. Domain Discovery

Define ubiquitous language. List domain events in past tense.

```
Domain: Order Management
Events: OrderPlaced, OrderCancelled, PaymentReceived
Aggregates: Order, Payment, Shipment
```

### 2. Contract First (if API exists)

Define API schema before writing code. See `references/api-first.md`.

### 3. Outside-In TDD

```
Acceptance Test (RED) -> Domain Test (RED->GREEN) -> Use Case Test (RED->GREEN) -> Adapter (GREEN) -> Acceptance (GREEN) -> Refactor
```

Full workflow in `references/tdd-ddd-workflow.md`.
</important>

<important if="structuring a project with Clean Architecture layers or creating module directory layout">
### 4. Layer Implementation

```
domain/           -> Entities, VOs, Events, Ports (zero dependencies)
application/      -> Use Cases, Commands, Queries (depends on domain only)
infrastructure/   -> DB adapters, API controllers (depends on all)
```

**Dependency Rule**: Inner layers NEVER import outer layers.

## Directory Structure

```
src/modules/{context-name}/
  domain/
    model/           # Aggregate Root, Entities, Value Objects
    events/          # Domain Events (past tense)
    ports/           # Repository & Service interfaces
    services/        # Domain Services (stateless)
  application/
    use-cases/       # One class per use case
    dto/             # Commands & Queries
  infrastructure/
    persistence/     # Repository implementations + Mappers
    api/             # HTTP Controllers / GraphQL Resolvers
    messaging/       # Event publishers / subscribers
```
</important>

<important if="naming DDD entities, value objects, events, repositories, or commands">
## Naming Conventions

| Concept | Pattern | Example |
|---------|---------|---------|
| Entity | Domain noun | `Order`, `Customer` |
| Value Object | Immutable concept | `Money`, `Address`, `Email` |
| Domain Event | Past tense | `OrderPlaced`, `PaymentReceived` |
| Use Case | Verb phrase | `PlaceOrder`, `CancelOrder` |
| Repository | `{Aggregate}Repository` | `OrderRepository` |
| Port | Interface in domain | `PaymentGateway` |
| Adapter | `{Tech}{Port}` | `StripePaymentGateway` |
| Command | `{Action}{Noun}Command` | `PlaceOrderCommand` |
| Query | `Get{Noun}Query` | `GetOrderQuery` |
</important>

<important if="implementing domain objects or reviewing domain model mutations">
## Immutability Rule

All domain objects return new instances. Never mutate.

```typescript
// CORRECT: return new instance
addItem(item: OrderItem): Order {
  return new Order(this.id, [...this._items, item], this._status)
}

// WRONG: mutation
addItem(item: OrderItem): void {
  this._items.push(item)  // VIOLATION
}
```
</important>

<important if="planning test strategy for a Clean Architecture project">
## Test Pyramid

| Layer | Type | Dependencies | Target |
|-------|------|-------------|--------|
| Domain | Unit | None (pure) | less than 1ms |
| Application | Unit | Mocked ports | less than 10ms |
| Infrastructure | Integration | Real DB | less than 500ms |
| E2E | Acceptance | Full stack | less than 3s |
</important>

<important if="deciding whether to apply DDD or assessing over-engineering risk">
## Error Handling

| Situation | Action |
|-----------|--------|
| Domain complexity unclear | Start with simple module; extract domain layer when rules emerge |
| Bounded Context boundaries uncertain | Map team/stakeholder language first; split where language diverges |
| Existing codebase has no layers | Introduce layers incrementally; start with domain extraction |
| Over-engineering risk | If entity has no business rules, use plain DTO -- skip DDD |
</important>

## References

- `references/ddd-tactical.md` -- Entity, VO, Aggregate, Repository, Domain Event, Factory (TS/Python/Go)
- `references/ddd-strategic.md` -- Bounded Context, Context Map, Anti-Corruption Layer
- `references/clean-architecture.md` -- Layers, Ports and Adapters, DI, testing per layer
- `references/event-driven.md` -- Event Bus, CQRS, Event Sourcing, Pub/Sub
- `references/api-first.md` -- OpenAPI, tRPC, GraphQL, versioning, error contracts
- `references/tdd-ddd-workflow.md` -- Outside-In TDD phases, property-based testing
