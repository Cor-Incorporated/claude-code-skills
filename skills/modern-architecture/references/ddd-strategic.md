# DDD Strategic Patterns

## Table of Contents
1. [Bounded Context](#bounded-context)
2. [Context Map](#context-map)
3. [Ubiquitous Language](#ubiquitous-language)
4. [Anti-Corruption Layer](#anti-corruption-layer)
5. [Shared Kernel](#shared-kernel)
6. [Domain Discovery Workflow](#domain-discovery-workflow)

---

## Bounded Context

A linguistic and model boundary. Same word can mean different things in different contexts.

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Sales Context   │    │ Shipping Context │    │ Billing Context  │
│                  │    │                  │    │                  │
│ Order = 見積/契約 │    │ Order = 配送指示  │    │ Order = 請求対象  │
│ Customer = 取引先 │    │ Customer = 届先   │    │ Customer = 請求先 │
│ Product = 商品    │    │ Product = 荷物    │    │ Product = 課金単位│
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### Directory structure per Bounded Context

```
src/
├── sales/                    # Sales Bounded Context
│   ├── domain/
│   │   ├── model/
│   │   │   ├── order.ts      # Aggregate Root
│   │   │   ├── customer.ts
│   │   │   └── value-objects/
│   │   ├── events/
│   │   │   └── order-placed.ts
│   │   ├── repositories/     # Port interfaces
│   │   │   └── order-repository.ts
│   │   └── services/
│   │       └── pricing-service.ts
│   ├── application/          # Use Cases
│   │   ├── place-order.ts
│   │   └── cancel-order.ts
│   └── infrastructure/       # Adapters
│       ├── persistence/
│       │   └── postgres-order-repository.ts
│       └── messaging/
│           └── order-event-publisher.ts
├── shipping/                 # Shipping Bounded Context
│   ├── domain/
│   ├── application/
│   └── infrastructure/
└── shared/                   # Shared Kernel (minimal)
    └── kernel/
        ├── money.ts
        └── event-bus.ts
```

### Identification heuristics
1. Different stakeholders use different language for same concept → separate contexts
2. Different invariants govern same-named concept → separate contexts
3. Changes in one area shouldn't require changes in another → separate contexts
4. One team per context (Conway's Law alignment)

---

## Context Map

Relationships between Bounded Contexts.

```
┌──────────┐  Upstream     ┌──────────┐
│  Sales   │──────────────▶│ Shipping │  (Customer/Supplier)
└──────────┘               └──────────┘
     │                          │
     │ Published Language       │ Conformist
     ▼                          ▼
┌──────────┐               ┌──────────┐
│ Billing  │◀──── ACL ────│ External │  (Anti-Corruption Layer)
└──────────┘               │ Payment  │
                           └──────────┘
```

### Relationship types

| Type | Description | When to use |
|------|-------------|-------------|
| **Partnership** | 両チームが協力して互いのコンテキストを進化 | 同一チーム or 密接に協力 |
| **Customer/Supplier** | 下流が上流に要求を出せる | 上流が下流のニーズに対応する意思あり |
| **Conformist** | 下流が上流のモデルにそのまま従う | 上流が変更に応じない場合 |
| **ACL** | 下流が変換層で上流モデルを隔離 | 外部システム統合 |
| **Shared Kernel** | 両コンテキストが一部モデルを共有 | 最小限の共有が効率的な場合 |
| **Published Language** | 上流が標準化されたスキーマを公開 | OpenAPI / Protocol Buffers |
| **Separate Ways** | 統合しない | コストがメリットを上回る場合 |

---

## Ubiquitous Language

Domain experts and developers share the same vocabulary. Code reflects the language.

```typescript
// ❌ Technical jargon
class OrderProcessor {
  processOrderEntity(data: OrderDTO): void {
    this.dbManager.insertRecord(data)
  }
}

// ✅ Ubiquitous Language
class OrderService {
  placeOrder(command: PlaceOrderCommand): OrderId {
    const order = Order.create(command.customerId, command.items)
    const placed = order.place()
    this.orderRepository.save(placed)
    return placed.id
  }
}
```

### Rules
- Method names match domain verbs: `place()`, `ship()`, `cancel()`, `refund()`
- Class names match domain nouns: `Order`, `Shipment`, `Invoice`
- No generic names: `Manager`, `Handler`, `Processor`, `Helper`, `Utils`
- If domain expert wouldn't understand the name, rename it

---

## Anti-Corruption Layer

Translate between your model and external systems.

```typescript
// External payment API returns its own model
interface StripePaymentResult {
  id: string
  status: 'succeeded' | 'failed' | 'pending'
  amount: number
  currency: string
  created: number
}

// ACL translates to your domain model
class PaymentGatewayACL implements PaymentGateway {
  constructor(private readonly stripe: StripeClient) {}

  async processPayment(payment: Payment): Promise<PaymentResult> {
    const stripeResult = await this.stripe.charges.create({
      amount: payment.amount.toCents(),
      currency: payment.amount.currency.toLowerCase(),
      source: payment.sourceToken,
    })

    // Translate external model → domain model
    return PaymentResult.from({
      transactionId: TransactionId.of(stripeResult.id),
      status: this.translateStatus(stripeResult.status),
      amount: Money.of(stripeResult.amount, stripeResult.currency.toUpperCase()),
      processedAt: new Date(stripeResult.created * 1000),
    })
  }

  private translateStatus(stripeStatus: string): PaymentStatus {
    const mapping: Record<string, PaymentStatus> = {
      succeeded: PaymentStatus.Completed,
      failed: PaymentStatus.Failed,
      pending: PaymentStatus.Pending,
    }
    return mapping[stripeStatus] ?? PaymentStatus.Unknown
  }
}
```

### When to use ACL
- Integrating with third-party APIs (Stripe, OpenAI, Twilio, etc.)
- Consuming legacy system data
- External models that change frequently
- Preventing external concepts from leaking into your domain

---

## Shared Kernel

Minimal shared code between contexts. Use sparingly.

```typescript
// shared/kernel/
export class Money { /* ... */ }
export class DateRange { /* ... */ }
export type EventId = string & { readonly __brand: 'EventId' }

// shared/kernel/events.ts
export interface DomainEvent {
  readonly eventId: EventId
  readonly occurredAt: Date
  readonly aggregateId: string
}
```

### Rules
1. Shared Kernel must be **tiny** — only truly universal concepts
2. Both teams must agree on changes
3. If in doubt, duplicate instead of sharing
4. Candidates: Money, DateRange, Address, basic event infrastructure

---

## Domain Discovery Workflow

### Step 1: Event Storming (Lightweight)

List domain events in past tense:
```
OrderPlaced → PaymentReceived → ShipmentDispatched → DeliveryConfirmed
                                                   → DeliveryFailed → ReturnInitiated
```

### Step 2: Identify Aggregates

Group events by the entity they affect:
```
Order:     OrderPlaced, OrderCancelled
Payment:   PaymentReceived, PaymentRefunded
Shipment:  ShipmentDispatched, DeliveryConfirmed, DeliveryFailed
```

### Step 3: Draw Context Boundaries

Group aggregates by team/language/invariant:
```
Sales Context:    Order, Customer, Product
Fulfillment:      Shipment, Warehouse
Billing:          Payment, Invoice, Refund
```

### Step 4: Map Relationships

Define how contexts communicate:
```
Sales --[OrderPlaced event]--> Fulfillment
Sales --[OrderPlaced event]--> Billing
Billing --[PaymentConfirmed event]--> Sales
Fulfillment --[ShipmentDispatched event]--> Sales
```

### Step 5: Define Published Language

For inter-context communication, define explicit contracts:
```typescript
// Published event schema (shared contract)
interface OrderPlacedEvent {
  version: '1.0'
  eventId: string
  orderId: string
  customerId: string
  items: Array<{ productId: string; quantity: number; unitPrice: number }>
  totalAmount: number
  currency: string
  placedAt: string  // ISO 8601
}
```
